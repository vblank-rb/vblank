/*
 * THE MUSIC PLAYER, the sound effects and the pitch wobble, swell and shape stepping that only
 * notes do. A port of rg_music.c, function for function (that file says every rule and the layout
 * of rg_game_music and rg_game_effects). A runtime feature (backends/runtime_features.rb), joined
 * into the script after rg_sound.js for a game that plays a tune or a sound effect, so it reads the
 * sound runtime's own voices as if it were written there. A game with neither builds without it.
 *
 * Its share of the sound runtime's hooks: the frame (sound_frame, after the mixer's slice is made
 * if the game has the mix feature), and a voice the game's own beep, wave or stop_wave took
 * (voice_taken_by_game).
 */

/* A song's notes on a recording are sounded by the mixer, when the game has the mix feature. A
 * recorded part can only exist in a game that has it (a recording is a declaration of the mix), so
 * a game with music and no recordings builds without the mixer: these then answer that nothing is
 * sounding, and no part ever asks. Asked once, as the script loads: a function declaration is
 * available from anywhere in the script, so the answer does not depend on which file comes first. */
const MUSIC_MIXES = typeof rg_mix_start_music_note === "function";
function mixer_start_note(effect, lane, rank, sound, loudness) {
  return MUSIC_MIXES ? rg_mix_start_music_note(effect, lane, rank, sound, loudness) : 0;
}
function mixer_glide_note(effect, lane, sound) { return MUSIC_MIXES ? rg_mix_glide_music_note(effect, lane, sound) : 0; }
function mixer_release_note(effect, lane) { return MUSIC_MIXES ? rg_mix_release_music(effect, lane) : 0; }
function mixer_release_all_notes() { if (MUSIC_MIXES) rg_mix_release_all_music(); }
function mixer_rescale_note(lane, loudness) { return MUSIC_MIXES ? rg_mix_rescale_music(lane, loudness) : 0; }

const PARTS_MOST = 20;
const NUMBERS_PER_NOTE = 6;
const PART_SQUARE = 0, PART_WAVE = 1, PART_NOISE = 2, PART_RECORDED = 3;
function SONG_COUNT() { return rg_game_music[0]; }
const SONG_STARTS = 1;
const NUMBERS_PER_SONG = 5;
const NUMBERS_PER_PART = 6;
function EFFECT_COUNT() { return rg_game_effects[0]; }
function EFFECTS_PLAY_WAVE() { return rg_game_effects[1]; }
const EFFECT_ROWS = 2;
const NUMBERS_PER_EFFECT = 6;
const EFFECT_SONG = 0, EFFECT_NOTES = 1, EFFECT_RANK = 2, EFFECT_GROUP = 3, EFFECT_PRIORITY = 4, EFFECT_KEEPS_VOICES = 5;
const EFFECTS_MOST = 512;

/* --- the player --- */

let wanted = -1;
let playing = -1;
let ended = -1;
let stops = 0;
let stops_seen = 0;
let music_held = false; // the game called hold_music: the tune stays where it is

let song = 0; /* where the playing song's numbers start in rg_game_music */
let song_frame = 0;
let part_count = 0;
const parts = [];
for (let i = 0; i < PARTS_MOST; i++) parts.push(null);

let level_variable = null; /* reads the game's music volume, for a game that keeps one */
let level = -1;

let holding = [];

function rg_music_request(number) {
  if (number < 0 || number >= SONG_COUNT()) rg_fault(`there is no song number ${number}`);
  wanted = number;
}

function rg_music_request_one_of(songs, count, which) {
  if (which >= 0 && which < count) rg_music_request(songs[which]);
}

function rg_music_stop() {
  wanted = -1;
  stops++;
}

// The tune stays where it is, or carries on (Reference::Player#hold).
function rg_music_hold(held) { music_held = held !== 0; }

function rg_music_follow_level(variable) { level_variable = variable; }

/* Where song number +number+'s numbers start, from its length on. */
function song_numbers(number) { return rg_game_music[SONG_STARTS + number]; }

/* The part of song number +number+ written at +part+ (a place in rg_game_music), as a walk of its
 * notes. Gives back the walk and where the song's next part is written. */
function read_part(number, part, again, squares_met) {
  const kind = rg_game_music[part], first = rg_game_music[part + 4], after = rg_game_music[part + 5];
  const first_notes = part + NUMBERS_PER_PART;
  const after_notes = first_notes + NUMBERS_PER_NOTE * first;
  const voice = kind === PART_WAVE ? RG_WAVE_VOICE
    : kind === PART_NOISE ? RG_NOISE_VOICE
      : kind === PART_RECORDED ? 0
        : ++squares_met.count;
  if (squares_met.count > RG_SQUARE_VOICES) {
    rg_fault(`song number ${number} has more parts on the square wave than the ${RG_SQUARE_VOICES} there are`);
  }
  const walk = { notes: again ? after_notes : first_notes, count: again ? after : first, next: 0, kind, voice,
    number: rg_game_music[part + 1], tone: rg_game_music[part + 2], fade: rg_game_music[part + 3] };
  return [walk, after_notes + NUMBERS_PER_NOTE * after];
}

function start_walks(again) {
  let part = song + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  for (let i = 0; i < part_count; i++) {
    const [walk, next] = read_part(playing, part, again, squares_met);
    parts[i] = walk;
    part = next;
  }
}

function scaled_volume(volume) { return (volume * level) >> LEVEL_SHIFT(); }

function wave_quarters_at(volume) {
  if (volume < 0) volume = 0;
  if (volume >= VOLUMES) volume = VOLUMES - 1;
  return rg_game_sound_rules[WAVE_QUARTERS + volume];
}

function log_held_loudness(note) {
  if (note.voice === 0) rg_sound_log(`mixer_loudness ${note.lane} ${scaled_volume(note.volume)}`);
  else rg_sound_log(`loudness ${note.voice} ${scaled_volume(note.volume)}`);
}

function hold_note(note) {
  let at = 0;
  while (at < holding.length && (holding[at].voice !== note.voice || (note.voice === 0 && holding[at].lane !== note.lane))) at++;
  holding[at] = note;
  log_held_loudness(note);
}

function follow_level(now) {
  if (now === level) return;
  level = now;
  for (const note of holding) {
    if (note.volume <= 0) continue;
    if (note.voice === 0 && !mixer_rescale_note(note.lane, scaled_volume(note.volume))) continue;
    log_held_loudness(note);
    if (note.voice === 0) continue;
    if (note.voice === RG_WAVE_VOICE) {
      wave_set_loudness(wave_quarters_at(scaled_volume(note.volume)));
    } else {
      square_start(note.voice, note.wave_ticks, note.eighths_high, scaled_volume(note.volume), note.fade, 0);
    }
  }
}

/* --- a pitch that wobbles (rg_sound.c's own section says how) --- */

function still_wobble() { return { vibrato: 0, wait: 0, left: 0, rising: 0, steps: 0, ticks: 0 }; }
const wobbles = Array.from({ length: RG_WAVE_VOICE + 1 }, still_wobble);

function note_vibrato(note) {
  const flags = rg_game_music[note + 4];
  return flags & HAS_VIBRATO ? (flags >>> VIBRATO_AT) & VIBRATO_BITS : 0;
}

function wobble_start(voice, note) {
  if (voice > RG_WAVE_VOICE) return;
  const vibrato = rg_game_music[note + 1] === 0 ? 0 : note_vibrato(note);
  const was = wobbles[voice];
  if ((vibrato & VIBRATO_FOUR_BITS) === 0) {
    was.vibrato = 0;
    was.steps = 0;
    return;
  }
  const carries = rg_game_music[note + 5] & CARRIES_VIBRATO;
  wobbles[voice] = { vibrato, wait: vibrato >> VIBRATO_AFTER_AT, left: carries ? was.left : 0, rising: carries ? was.rising : 0,
                     steps: 0, ticks: rg_game_music[note + 3] };
}

function wobble_stop(voice) {
  if (voice <= RG_WAVE_VOICE) wobbles[voice].vibrato = 0;
}

function step_wobbles() {
  for (let voice = 1; voice <= RG_WAVE_VOICE; voice++) {
    const moving = wobbles[voice];
    const depth = moving.vibrato & VIBRATO_FOUR_BITS;
    if (depth === 0 || held_still(voice)) continue;
    if (moving.wait > 0) {
      moving.wait--;
      continue;
    }
    if (moving.left === 0) {
      moving.rising = moving.rising ? 0 : 1;
      moving.left = ((moving.vibrato >> VIBRATO_SPEED_AT) & VIBRATO_FOUR_BITS) + 1; // kept less one
      const steps = moving.rising ? Math.trunc((depth + 1) / 2) : -Math.trunc(depth / 2);
      if (steps !== moving.steps) rg_sound_log(`wobble ${voice} ${steps}`);
      moving.steps = steps;
    }
    moving.left--;
    let count = PITCH_COUNT_TOP - moving.ticks + moving.steps;
    if (count < 0) count = 0;
    if (count > PITCH_COUNT_TOP - 1) count = PITCH_COUNT_TOP - 1;
    if (voice === RG_WAVE_VOICE) {
      if (wave.wave_ticks !== 0) wave.wave_ticks = PITCH_COUNT_TOP - count;
    } else if (squares[voice - 1].wave_ticks !== 0) {
      squares[voice - 1].slid_ticks = PITCH_COUNT_TOP - count;
    }
  }
}

/* A SQUARE NOTE'S SHAPES, by its voice: rg_sound.c's shape_walk. */
const shapes = [null, { bits: 0, frame: 0, steps: 0 }, { bits: 0, frame: 0, steps: 0 }];
const EIGHTHS_OF_SHAPE = [1, 2, 4, 6];

function shape_at(bits, frame) { return (bits >> (2 * (frame % 4))) & 3; }

function note_eighths(part, note) {
  const flags = rg_game_music[note + 5];
  return flags & HAS_DUTY ? EIGHTHS_OF_SHAPE[shape_at(flags, 0)] : part.tone;
}

function shape_start(voice, note) {
  swell_stop(voice);
  if (voice > RG_SQUARE_VOICES) return;
  const flags = rg_game_music[note + 5];
  const bits = rg_game_music[note + 1] !== 0 && (flags & HAS_DUTY) ? flags & DUTY_BITS : 0;
  let steps = 0;
  for (let frame = 1; frame < 4; frame++) if (shape_at(bits, frame) !== shape_at(bits, 0)) steps = 1;
  shapes[voice] = { bits, frame: 0, steps };
}

function shape_stop(voice) {
  if (voice <= RG_SQUARE_VOICES) shapes[voice].steps = 0;
  swell_stop(voice);
}

/* A SONG'S SWELLING NOTE HELD UNDER THE MUSIC VOLUME, by its voice: rg_sound.c's swell_walk. */
const swells = [null, { active: 0 }, { active: 0 }, { active: 0 }, { active: 0 }];

function swell_stop(voice) {
  swells[voice].active = 0;
}

function swell_strike(voice, swell, volume, fade) {
  if (voice === RG_NOISE_VOICE) noise_start(swell.wave_ticks, swell.eighths_high, volume, fade);
  else square_start(voice, swell.wave_ticks, swell.eighths_high, volume, fade, 0);
}

function swell_start(voice, note, eighths_high, volume, fade) {
  if (rg_game_music[note + 1] === 0 || !(fade & FADE_UP) || (fade & FADE_STEP_BITS) === 0) return;
  swells[voice] = { active: 1, step: fade & FADE_STEP_BITS, volume, counted: 0, swelling: 1,
                    wave_ticks: rg_game_music[note + 3], eighths_high };
}

/* rg_sound.c's step_swells: each struck again where the music volume sets, then counted a frame. */
function step_swells() {
  const ceiling = (LOUDEST * level) >> LEVEL_SHIFT();
  for (let voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    const swell = swells[voice];
    if (!swell.active) continue;
    if (swell.swelling ? swell.volume >= ceiling && ceiling < LOUDEST : swell.volume > ceiling) {
      swell.volume = ceiling;
      swell.counted = 0;
      swell.swelling = 0;
      rg_sound_log(`loudness ${voice} ${ceiling}`);
      swell_strike(voice, swell, ceiling, 0);
    } else if (!swell.swelling && swell.volume < ceiling) {
      swell.counted = 0;
      swell.swelling = 1;
      rg_sound_log(`loudness ${voice} ${swell.volume} ${FADE_UP | swell.step}`);
      swell_strike(voice, swell, swell.volume, FADE_UP | swell.step);
    }
    if (!swell.swelling || swell.volume >= LOUDEST) continue;
    swell.counted += COUNTED_A_FRAME();
    while (swell.counted >= swell.step * 256 && swell.volume < LOUDEST) {
      swell.counted -= swell.step * 256;
      swell.volume++;
    }
  }
}

function step_shapes() {
  for (let voice = 1; voice <= RG_SQUARE_VOICES; voice++) {
    const walk = shapes[voice];
    if (!walk.steps || held_still(voice)) continue;
    const now = shape_at(walk.bits, walk.frame);
    if (walk.frame > 0 && now !== shape_at(walk.bits, walk.frame - 1)) rg_sound_log(`duty ${voice} ${now}`);
    squares[voice - 1].eighths_high = EIGHTHS_OF_SHAPE[now];
    walk.frame++;
  }
}

function silence_voice(voice) {
  wobble_stop(voice);
  shape_stop(voice);
  switch (voice) {
    case RG_WAVE_VOICE: wave_set_loudness(0); break;
    case RG_NOISE_VOICE: noise_start(0, hiss.bits, 0, 0); break;
    default: square_start(voice, 0, 0, 0, 0, 0); break;
  }
}

function rest_on(part) {
  if (part.kind !== PART_RECORDED) silence_voice(part.voice);
}

/* --- who holds a console voice --- */

function ORDER_MASK() { return rg_game_sound_rules[WAVE_QUARTERS + VOLUMES]; }
const holders = [0, 0, 0, 0, 0];

// Is the note on +voice+ the held tune's? A sound effect on a voice keeps moving.
function held_still(voice) { return music_held && (holders[voice] & ORDER_MASK()) === 0; }
const holder_order = [];

function claim_voice(voice, rank, sounds) {
  if (holders[voice] > rank) return 0;
  if (!holder_order.includes(voice)) holder_order.push(voice);
  holders[voice] = sounds ? rank : 0;
  return 1;
}

function note_sounds(kind, pitch, volume, fade) {
  if (pitch === 0) return 0;
  if ((fade & FADE_UP) && (fade & FADE_STEP_BITS) && (kind === PART_SQUARE || kind === PART_NOISE)) return 1;
  if (volume <= 0) return 0;
  return kind !== PART_WAVE || wave_quarters_at(volume) !== 0 ? 1 : 0;
}

function wave_put_in(which) {
  if (which === loaded_waveform) return;
  wave_load(which);
}

function silence_song() {
  rg_sound_log("stop_music");
  for (let i = 0; i < part_count; i++) {
    if (parts[i].kind === PART_RECORDED || (holders[parts[i].voice] & ORDER_MASK()) !== 0) continue;
    rest_on(parts[i]);
  }
  for (let voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    if ((holders[voice] & ORDER_MASK()) === 0) holders[voice] = 0;
  }
  holding = [];
  mixer_release_all_notes();
}

function switch_to_wanted_song() {
  if (ended >= 0) {
    if (wanted === ended && stops === stops_seen) {
      if (playing >= 0) silence_song();
      playing = -1;
      return false;
    }
    ended = -1;
  }
  if (wanted === playing && stops === stops_seen) return false;

  stops_seen = stops;
  music_held = false;
  if (playing >= 0) silence_song();
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return true;

  song = song_numbers(playing);
  part_count = rg_game_music[song + 4];
  if (part_count > PARTS_MOST) rg_fault(`song number ${playing} has ${part_count} parts, and the most is ${PARTS_MOST}`);
  start_walks(0);
  if (EFFECTS_PLAY_WAVE()) return true;
  for (let i = 0; i < part_count; i++) {
    if (parts[i].kind !== PART_WAVE) continue;
    wave_load(parts[i].tone);
    break;
  }
  return true;
}

function play_recorded_note(part, note) {
  const pitch = rg_game_music[note + 1], loudness = rg_game_music[note + 2], sound = rg_game_music[note + 3];
  if (pitch === 0 || loudness <= 0) {
    mixer_release_note(-1, part.tone);
  } else {
    const numbers = 1 + sound * NUMBERS_PER_NOTE_SOUND;
    const heard = rg_game_music[note + 5] & GLIDES ? mixer_glide_note(-1, part.tone, numbers)
      : mixer_start_note(-1, part.tone, rg_game_music[song + 3], numbers, level_variable ? scaled_volume(loudness) : loudness);
    if (!heard) return;
  }
  rg_sound_log(`note ${playing} ${pitch}`);
  if (level_variable) hold_note({ voice: 0, lane: part.tone, volume: pitch === 0 ? 0 : loudness, wave_ticks: 0, eighths_high: 0, fade: 0 });
}

function note_fade(part, note) {
  const flags = rg_game_music[note + 4];
  if (flags & HAS_FADE) return flags & (FADE_UP | FADE_STEP_BITS);
  return part.kind === PART_NOISE ? part.fade : 0;
}

function note_slide(note) { return (rg_game_music[note + 4] >> SLIDE_AT) & SLIDE_BITS; }

function note_pan(note) { return (rg_game_music[note + 4] >>> PAN_AT) & PAN_BITS; }

function log_voice_set(voice, who, pitch, volume, note) {
  const flags = rg_game_music[note + 4];
  const after = [flags & HAS_FADE ? flags & (FADE_UP | FADE_STEP_BITS) : -1,
                 flags & HAS_SLIDE ? note_slide(note) : -1,
                 flags & HAS_VIBRATO ? note_vibrato(note) | (rg_game_music[note + 5] & CARRIES_VIBRATO ? VIBRATO_CARRIES_LOGGED : 0) : -1,
                 note_pan(note) || -1,
                 rg_game_music[note + 5] & HAS_DUTY ? rg_game_music[note + 5] & DUTY_BITS : -1];
  while (after.length > 0 && after[after.length - 1] < 0) after.pop();
  rg_sound_log([`voice ${voice} ${who} ${pitch} ${volume}`, ...after].join(" "));
}

function play_note(part, note) {
  if (part.kind === PART_RECORDED) {
    play_recorded_note(part, note);
    return;
  }

  const pitch = rg_game_music[note + 1], volume = rg_game_music[note + 2], ticks = rg_game_music[note + 3];
  if (!claim_voice(part.voice, rg_game_music[song + 3], note_sounds(part.kind, pitch, volume, note_fade(part, note)))) return;

  const written = pitch === 0 ? 0 : volume;
  const sounded = level_variable ? scaled_volume(written) : written;
  const fade = note_fade(part, note);
  rg_sound_log(`note ${playing} ${pitch}`);
  log_voice_set(part.voice, playing, pitch, volume, note);
  wobble_start(part.voice, note);
  shape_start(part.voice, note);
  sides[part.voice] = note_pan(note);
  switch (part.kind) {
    case PART_WAVE:
      if (level_variable) hold_note({ voice: part.voice, lane: 0, volume: written, wave_ticks: 0, eighths_high: 0, fade: 0 });
      if (pitch === 0) {
        rg_sound_log("stop_wave");
        rest_on(part);
      } else {
        rg_sound_log(`part_wave ${playing} ${part.number} ${pitch}`);
        if (EFFECTS_PLAY_WAVE()) wave_put_in(part.tone);
        wave_start(ticks, wave_quarters_at(sounded));
      }
      break;
    case PART_NOISE:
      if (level_variable) rg_sound_log(`loudness ${part.voice} ${sounded}`);
      if (pitch === 0) {
        rg_sound_log("noise_rest");
        rest_on(part);
      } else {
        rg_sound_log(`part_noise ${playing} ${part.number} ${pitch}`);
        noise_start(ticks, part.tone, sounded, fade);
        if (level_variable) swell_start(part.voice, note, part.tone, sounded, fade);
      }
      break;
    default:
      // A note that fades, swells or slides by itself is left to it (rg_sound.c's play_note says why).
      if (level_variable && ((fade & FADE_STEP_BITS) !== 0 || note_slide(note) !== 0)) {
        drop_held_note(part.voice);
        rg_sound_log(`loudness ${part.voice} ${sounded}`);
      } else if (level_variable) {
        hold_note({ voice: part.voice, lane: 0, volume: written, wave_ticks: ticks, eighths_high: note_eighths(part, note), fade });
      }
      square_start(part.voice, ticks, note_eighths(part, note), sounded, fade, note_slide(note));
      if (level_variable && note_slide(note) === 0) swell_start(part.voice, note, note_eighths(part, note), sounded, fade);
      break;
  }
}

/* --- sound effects --- */

const effect_asked = new Uint8Array(EFFECTS_MOST);
const effect_asked_now = new Uint8Array(EFFECTS_MOST);
const effect_stopping = new Uint8Array(EFFECTS_MOST);
const effect_running = new Uint8Array(EFFECTS_MOST);
const effect_frame = new Int32Array(EFFECTS_MOST);
const effect_cursors = [];
for (let i = 0; i < EFFECTS_MOST; i++) effect_cursors.push(null);

function effect_row(effect) { return EFFECT_ROWS + effect * NUMBERS_PER_EFFECT; }
function effect_field(effect, field) { return rg_game_effects[effect_row(effect) + field]; }

function effect_pending(effect) {
  return effect_asked[effect] || (effect_running[effect] && !effect_stopping[effect]);
}

function refuse_too_many_effects() {
  if (EFFECT_COUNT() > EFFECTS_MOST) rg_fault(`the game has ${EFFECT_COUNT()} sound effects, and the most is ${EFFECTS_MOST}`);
}

function request_effect(effect) {
  refuse_too_many_effects();
  if (effect_field(effect, EFFECT_GROUP) >= 0) {
    for (let other = 0; other < EFFECT_COUNT(); other++) {
      if (effect_field(other, EFFECT_GROUP) !== effect_field(effect, EFFECT_GROUP) || !effect_pending(other)) continue;
      if (effect_field(effect, EFFECT_PRIORITY) < effect_field(other, EFFECT_PRIORITY)) return;
      effect_asked[other] = 0;
      effect_stopping[other] = 1;
      break;
    }
  }
  effect_asked[effect] = 1;
}

function rg_effect_request_one_of(effects, count, which) {
  if (which >= 0 && which < count) request_effect(effects[which]);
}

function drop_held_note(voice) { holding = holding.filter((note) => note.voice !== voice); }

function finish_effect(effect) {
  const number = effect_field(effect, EFFECT_SONG), rank = effect_field(effect, EFFECT_RANK);
  effect_running[effect] = 0;
  for (const voice of holder_order) {
    if (holders[voice] !== rank) continue;
    holders[voice] = 0;
    rg_sound_log(`note ${number} 0`);
    rg_sound_log(`voice ${voice} ${number} 0 0`);
    if (voice === RG_NOISE_VOICE) rg_sound_log("noise_rest");
    if (voice === RG_WAVE_VOICE) rg_sound_log("stop_wave");
    silence_voice(voice);
  }

  const numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  let part = numbers + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  for (let i = 0; i < rg_game_music[numbers + 4]; i++) {
    const [walk, next] = read_part(number, part, 0, squares_met);
    part = next;
    if (walk.kind === PART_RECORDED && mixer_release_note(effect, walk.tone)) rg_sound_log(`note ${number} 0`);
  }
}

function play_effect_note(effect, part, note) {
  const number = effect_field(effect, EFFECT_SONG), rank = effect_field(effect, EFFECT_RANK);
  const pitch = rg_game_music[note + 1], volume = rg_game_music[note + 2];
  const sounds = note_sounds(part.kind, pitch, volume, note_fade(part, note));

  if (part.kind === PART_RECORDED) {
    const sound = rg_game_music[note + 3];
    const loudness = rg_game_music[note + 2];
    const numbers = 1 + sound * NUMBERS_PER_NOTE_SOUND;
    const was_heard = !sounds ? mixer_release_note(effect, part.tone)
      : rg_game_music[note + 5] & GLIDES ? mixer_glide_note(effect, part.tone, numbers)
        : mixer_start_note(effect, part.tone, rank, numbers, loudness);
    if (was_heard) rg_sound_log(`note ${number} ${pitch}`);
    return;
  }
  if (!claim_voice(part.voice, rank, sounds || effect_field(effect, EFFECT_KEEPS_VOICES) === 1)) return;

  const ticks = rg_game_music[note + 3], fade = note_fade(part, note);
  drop_held_note(part.voice);
  rg_sound_log(`note ${number} ${pitch}`);
  log_voice_set(part.voice, number, pitch, volume, note);
  wobble_start(part.voice, note);
  shape_start(part.voice, note);
  sides[part.voice] = note_pan(note);
  switch (part.kind) {
    case PART_WAVE:
      if (pitch === 0) {
        rg_sound_log("stop_wave");
        silence_voice(part.voice);
      } else {
        rg_sound_log(`part_wave ${number} ${part.number} ${pitch}`);
        wave_put_in(part.tone);
        wave_start(ticks, wave_quarters_at(volume));
      }
      break;
    case PART_NOISE:
      if (pitch === 0) {
        rg_sound_log("noise_rest");
        silence_voice(part.voice);
      } else {
        rg_sound_log(`part_noise ${number} ${part.number} ${pitch}`);
        noise_start(ticks, part.tone, volume, fade);
      }
      break;
    default: square_start(part.voice, ticks, note_eighths(part, note), pitch === 0 ? 0 : volume, fade, note_slide(note)); break;
  }
}

function play_effect_frame(effect) {
  const number = effect_field(effect, EFFECT_SONG);
  const numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  if (effect_stopping[effect]) {
    effect_stopping[effect] = 0;
    finish_effect(effect);
  }
  if (effect_asked_now[effect]) {
    effect_running[effect] = 1;
    effect_frame[effect] = 0;
    effect_cursors[effect] = new Int32Array(PARTS_MOST);
    rg_sound_log(`sound_effect ${effect}`);
  } else if (effect_running[effect] && effect_frame[effect] >= rg_game_music[numbers]) {
    finish_effect(effect);
  }
  if (!effect_running[effect]) return;

  const part_total = rg_game_music[numbers + 4];
  if (part_total > PARTS_MOST) rg_fault(`a sound effect has ${part_total} parts, and the most is ${PARTS_MOST}`);
  let part = numbers + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  const cursors = effect_cursors[effect];
  for (let i = 0; i < part_total; i++) {
    const [walk, next] = read_part(number, part, 0, squares_met);
    part = next;
    if (cursors[i] >= walk.count) continue;
    const note = walk.notes + NUMBERS_PER_NOTE * cursors[i];
    if (rg_game_music[note] !== effect_frame[effect]) continue;
    cursors[i]++;
    play_effect_note(effect, walk, note);
  }
  effect_frame[effect]++;
}

/* --- the frame --- */

function effects_by_rank() { return EFFECT_ROWS + EFFECT_COUNT() * NUMBERS_PER_EFFECT; }

function rg_music_sound_frame() {
  if (level < 0) level = FULL_LEVEL();
  refuse_too_many_effects();
  switch_to_wanted_song();
  for (let effect = 0; effect < EFFECT_COUNT(); effect++) {
    effect_asked_now[effect] = effect_asked[effect];
    effect_asked[effect] = 0;
  }
  const tune = playing >= 0 ? rg_game_music[song + 3] : -1;
  const by_rank = effects_by_rank();
  let at = 0;
  while (at < EFFECT_COUNT() && effect_field(rg_game_effects[by_rank + at], EFFECT_RANK) > tune) {
    play_effect_frame(rg_game_effects[by_rank + at++]);
  }
  if (playing >= 0) play_song_frame();
  while (at < EFFECT_COUNT()) play_effect_frame(rg_game_effects[by_rank + at++]);
  step_swells();
  step_wobbles();
  step_shapes();
}

function rg_music_start_here() {
  if (level < 0) level = FULL_LEVEL();
  if (switch_to_wanted_song() && playing >= 0) play_song_frame();
}

function rg_effect_start_here_one_of(effects, count, which) {
  if (which < 0 || which >= count) return;
  const asked = effects[which];
  request_effect(asked);
  if (!effect_asked[asked]) return;

  const by_rank = effects_by_rank();
  for (let at = 0; at < EFFECT_COUNT(); at++) {
    const effect = rg_game_effects[by_rank + at];
    if (effect === asked) {
      effect_asked[asked] = 0;
      effect_asked_now[asked] = 1;
      play_effect_frame(asked);
      effect_asked_now[asked] = 0;
    } else if (effect_stopping[effect]) {
      effect_stopping[effect] = 0;
      finish_effect(effect);
    }
  }
}

function rg_music_start_here_one_of(songs, count, which) {
  if (which < 0 || which >= count) return;
  rg_music_request(songs[which]);
  rg_music_start_here();
}

function play_song_frame() {
  if (level_variable) follow_level(level_variable());
  if (music_held) return;
  for (let i = 0; i < part_count; i++) {
    const part = parts[i];
    if (part.next >= part.count) continue;
    const note = part.notes + NUMBERS_PER_NOTE * part.next;
    if (rg_game_music[note] !== song_frame) continue;

    play_note(part, note);
    part.next++;
  }

  song_frame++;
  if (song_frame < rg_game_music[song]) return;
  if (rg_game_music[song + 2]) {
    ended = playing;
    return;
  }
  song_frame = rg_game_music[song + 1];
  start_walks(1);
}

/* The game's own beep, wave or stop_wave took +voice+ (Reference::Player#game_sound_on): a song's
 * note there no longer wobbles or steps its shapes. */
function rg_music_voice_taken_by_game(voice) {
  wobble_stop(voice);
  shape_stop(voice);
}

/* rg_hook_moment_printed, asked only by the windowless run (rg_headless.js): the tune the player
 * is on, by the number the log names it by, -1 for none (Reference#music_playing). */
function rg_music_moment_printed() {
  headless_print(`music_playing ${playing}\n`);
}

/* --- the state image (rg_music.c says what each field holds) --- */

const PART_STATE_NUMBERS = 2, HELD_NOTE_NUMBERS = 6, WOBBLE_NUMBERS = 6, SWELL_NUMBERS = 7, SHAPE_NUMBERS = 3;
const EFFECT_STATE_NUMBERS = 5 + PARTS_MOST;

function refuse_damaged_music(what) { rg_fault(`This state is damaged: ${what}. Load a state that this game wrote.`); }

/* rg_hook_visit_sound_state (rg_music.c's rg_music_visit_sound_state). */
function rg_music_visit_sound_state() {
  const reading = rg_state_reading();
  const general = [wanted, playing, ended, stops, stops_seen, music_held ? 1 : 0, song_frame, level, holding.length,
    holder_order.length];
  rg_state_numbers("music", general);
  if (general[0] < -1 || general[0] >= SONG_COUNT() || general[1] < -1 || general[1] >= SONG_COUNT() || general[2] < -1 ||
      general[2] >= SONG_COUNT() || general[8] < 0 || general[8] > PARTS_MOST || general[9] < 0 || general[9] > RG_NOISE_VOICE) {
    refuse_damaged_music("the music holds more than it can");
  }
  [wanted, playing, ended, stops, stops_seen] = general;
  music_held = general[5] !== 0;
  [song_frame, level] = [general[6], general[7]];

  if (reading) {
    song = playing >= 0 ? song_numbers(playing) : 0;
    part_count = playing >= 0 ? rg_game_music[song + 4] : 0;
    if (part_count > PARTS_MOST) refuse_damaged_music("the song has more parts than a song can");
  }
  const squares_met = { count: 0 };
  let written = song + NUMBERS_PER_SONG;
  const walks = [];
  for (let i = 0; !reading && i < part_count; i++) {
    const [first, next] = read_part(playing, written, 0, squares_met);
    written = next;
    walks.push(parts[i].notes !== first.notes || parts[i].count !== first.count ? 1 : 0, parts[i].next);
  }
  if (reading) walks.push(...new Array(part_count * PART_STATE_NUMBERS).fill(0));
  rg_state_numbers("music.parts", walks);
  for (let i = 0; reading && i < part_count; i++) {
    const [walk, next] = read_part(playing, written, walks[i * PART_STATE_NUMBERS] !== 0, squares_met);
    written = next;
    const at = walks[i * PART_STATE_NUMBERS + 1];
    if (at < 0 || at > walk.count) refuse_damaged_music("a part of the song is past its last note");
    walk.next = at;
    parts[i] = walk;
  }

  const held = reading ? new Array(general[8] * HELD_NOTE_NUMBERS).fill(0) :
    holding.flatMap((h) => [h.voice, h.lane, h.volume, h.wave_ticks, h.eighths_high, h.fade]);
  rg_state_numbers("music.holding", held);
  holding = [];
  for (let i = 0; i < general[8]; i++) {
    const n = held.slice(i * HELD_NOTE_NUMBERS, (i + 1) * HELD_NOTE_NUMBERS);
    if (n[0] < 0 || n[0] > RG_NOISE_VOICE) refuse_damaged_music("a held note is on a voice there is not");
    holding.push({ voice: n[0], lane: n[1], volume: n[2], wave_ticks: n[3], eighths_high: n[4], fade: n[5] });
  }

  const voices = [];
  for (let v = 1; v <= RG_WAVE_VOICE; v++) {
    const w = wobbles[v];
    voices.push(w.vibrato, w.wait, w.left, w.rising, w.steps, w.ticks);
  }
  for (let v = 1; v <= RG_NOISE_VOICE; v++) {
    const s = swells[v];
    voices.push(s.active, s.step ?? 0, s.volume ?? 0, s.counted ?? 0, s.swelling ?? 0, s.wave_ticks ?? 0, s.eighths_high ?? 0);
  }
  for (let v = 1; v <= RG_SQUARE_VOICES; v++) voices.push(shapes[v].bits, shapes[v].frame, shapes[v].steps);
  for (let v = 1; v <= RG_NOISE_VOICE; v++) voices.push(holders[v]);
  for (let i = 0; i < RG_NOISE_VOICE; i++) voices.push(holder_order[i] ?? 0);
  rg_state_numbers("music.voices", voices);
  let at = 0;
  for (let v = 1; v <= RG_WAVE_VOICE; v++, at += WOBBLE_NUMBERS) {
    const n = voices.slice(at, at + WOBBLE_NUMBERS);
    wobbles[v] = { vibrato: n[0], wait: n[1], left: n[2], rising: n[3], steps: n[4], ticks: n[5] };
  }
  for (let v = 1; v <= RG_NOISE_VOICE; v++, at += SWELL_NUMBERS) {
    const n = voices.slice(at, at + SWELL_NUMBERS);
    swells[v] = { active: n[0], step: n[1], volume: n[2], counted: n[3], swelling: n[4], wave_ticks: n[5], eighths_high: n[6] };
  }
  for (let v = 1; v <= RG_SQUARE_VOICES; v++, at += SHAPE_NUMBERS) {
    shapes[v] = { bits: voices[at], frame: voices[at + 1], steps: voices[at + 2] };
  }
  for (let v = 1; v <= RG_NOISE_VOICE; v++) holders[v] = voices[at + v - 1];
  holder_order.length = 0;
  for (let i = 0; i < general[9]; i++) {
    const voice = voices[at + RG_NOISE_VOICE + i];
    if (voice < 1 || voice > RG_NOISE_VOICE) refuse_damaged_music("a voice is held that there is not");
    holder_order.push(voice);
  }

  const effects = [];
  for (let e = 0; e < EFFECT_COUNT(); e++) {
    effects.push(effect_asked[e], effect_asked_now[e], effect_stopping[e], effect_running[e], effect_frame[e]);
    for (let p = 0; p < PARTS_MOST; p++) effects.push(effect_cursors[e] ? effect_cursors[e][p] : 0);
  }
  rg_state_numbers("music.effects", effects);
  for (let e = 0; e < EFFECT_COUNT(); e++) {
    const n = effects.slice(e * EFFECT_STATE_NUMBERS, (e + 1) * EFFECT_STATE_NUMBERS);
    effect_asked[e] = n[0] !== 0 ? 1 : 0;
    effect_asked_now[e] = n[1] !== 0 ? 1 : 0;
    effect_stopping[e] = n[2] !== 0 ? 1 : 0;
    effect_running[e] = n[3] !== 0 ? 1 : 0;
    effect_frame[e] = n[4];
    effect_cursors[e] = Int32Array.from(n.slice(5));
  }
}
