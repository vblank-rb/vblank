/*
 * THE MIXER: several recordings sounding at once, added together a frame at a time into one stream
 * of sound, the way the console's own software mixer does it. A port of the native runtime's
 * rg_mix.c, function for function; that file says the arithmetic and the layout of rg_game_mix and
 * rg_game_recordings, and this one keeps both to the bit. A product too big for 32 bits is worked
 * out as a float, which holds it exactly, and brought down by rounding down, as the C's 64-bit
 * shift does.
 *
 * A runtime feature (backends/runtime_features.rb), joined into the script after rg_sound.js for a
 * game that declares a recording; it takes the sound_frame, sound_frame_ended, mixed_slice and
 * mixed_sample_shift hooks.
 */

const VOICES_MOST = 16;
const NUMBERS_PER_RECORDING = 7;

function MIXES() { return rg_game_mix[0]; }
function SLICE_SAMPLES() { return rg_game_mix[1]; }
function SHAPES() { return rg_game_mix[2]; }
function SLIDE_SHARE() { return rg_game_mix[3]; }
function VOICES() { return rg_game_mix[4]; }
function VOL_SHIFT() { return rg_game_mix[5]; }
function STEP_SHIFT() { return rg_game_mix[6]; }
function GAIN_FRACTION() { return rg_game_mix[7]; }
function RAMP_SPLIT() { return rg_game_mix[8]; }
function SHAPE_FULL() { return rg_game_mix[9]; }
function SHAPE_SCALE() { return rg_game_mix[10]; }
function LOUDNESS_TO_GAIN() { return rg_game_mix[11]; }
function WHOLE_GAIN_SHIFT() { return rg_game_mix[12]; }
function FULL_DEPTH_SHIFT() { return rg_game_mix[13]; }

const CLIMBING = 0, HOLDING = 1, FALLING = 2, DONE = 3;
const GAME = 0, SONG = 1, EFFECT = 2;

function silent_mix_voice() {
  return { sounding: 0, owner: GAME, effect: 0, lane: 0, rank: 0, loops: 0, ticket: 0, recording: 0, position: 0,
    fraction: 0, step: 0, back: 0, loudness: 0, gain: 0, ramp: 0, shaped: 0, level: 0, phase: CLIMBING, attack: 0,
    decay: 0, sustain: 0, release: 0 };
}

const mix_voices = [];
for (let i = 0; i < VOICES_MOST; i++) mix_voices.push(silent_mix_voice());
let slice = null;
let slices_made = 0;
let peak = 0;
let drops = 0;
let drops_music = 0;
let tickets = 0;

/* Where recording number +recording+'s numbers start in rg_game_recordings. */
function recording_numbers(recording) {
  if (recording < 0 || recording >= rg_game_recordings[0]) rg_fault(`there is no recording number ${recording}`);
  return 1 + recording * NUMBERS_PER_RECORDING;
}

function voices_sounding() {
  let count = 0;
  for (let i = 0; i < VOICES(); i++) count += mix_voices[i].sounding;
  return count;
}

function record_peak() {
  const now = voices_sounding();
  if (now > peak) peak = now;
}

function record_drop() {
  let music = 0;
  for (let i = 0; i < VOICES(); i++) music += mix_voices[i].sounding && mix_voices[i].owner !== GAME ? 1 : 0;
  drops++;
  if (music > drops_music) drops_music = music;
}

function free_voice() {
  if (VOICES() > VOICES_MOST) rg_fault(`the mixer has ${VOICES()} voices, and the most is ${VOICES_MOST}`);
  for (let i = 0; i < VOICES(); i++) {
    if (!mix_voices[i].sounding) return i;
  }
  return -1;
}

function releasing(voice) { return voice.owner !== GAME && (voice.phase === FALLING || voice.phase === DONE); }

function quietest_releasing_voice() {
  let found = -1;
  for (let i = 0; i < VOICES(); i++) {
    if (!mix_voices[i].sounding || !releasing(mix_voices[i])) continue;
    if (found < 0 || mix_voices[i].level < mix_voices[found].level) found = i;
  }
  return found;
}

function lowest_ranked_voice_below(rank) {
  let found = -1;
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.rank >= rank) continue;
    if (found >= 0) {
      const best = mix_voices[found];
      if (voice.rank > best.rank) continue;
      if (voice.rank === best.rank && (voice.loops > best.loops || (voice.loops === best.loops && voice.ticket >= best.ticket))) {
        continue;
      }
    }
    found = i;
  }
  return found;
}

/* A voice at the top of +recording+, shaped by the five numbers of +shape+ from +at+ (whether it
 * has one, then its four numbers). */
function start_voice(voice_at, recording, step, back, loudness, shape, at) {
  recording_numbers(recording);
  const shaped = shape[at];
  const voice = silent_mix_voice();
  Object.assign(voice, { sounding: 1, owner: GAME, rank: -1, recording, step, back, loudness,
    gain: shaped ? 0 : loudness << LOUDNESS_TO_GAIN(), shaped, level: shaped ? 0 : SHAPE_FULL(), phase: CLIMBING,
    attack: shape[at + 1], decay: shape[at + 2], sustain: shape[at + 3], release: shape[at + 4] });
  mix_voices[voice_at] = voice;
}

function rg_mix_play(recording, step, loudness, back, loops) {
  rg_sound_log(`sample ${recording}`);
  let at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) {
    record_drop();
    return;
  }

  start_voice(at, recording, step, back, loudness, rg_game_recordings, recording_numbers(recording) + 2);
  mix_voices[at].loops = loops;
  mix_voices[at].ticket = ++tickets;
  spu_recording_struck(at, 1);
  record_peak();
}

function sounding_voice(effect, lane) {
  const owner = effect < 0 ? SONG : EFFECT;
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.owner !== owner || voice.lane !== lane || releasing(voice)) continue;
    if (owner === SONG || voice.effect === effect) return i;
  }
  return -1;
}

function start_release(voice) {
  if (!voice.shaped) return 0;
  voice.phase = FALLING;
  return 1;
}

/* Reference::Mixer#glide_music_note: the note sounding reads on at the row's pitch. */
function rg_mix_glide_music_note(effect, lane, sound) {
  const at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  mix_voices[at].step = rg_game_note_sounds[sound + 1];
  return 1;
}

/* +sound+ is where the note's eight numbers start in rg_game_note_sounds. */
function rg_mix_start_music_note(effect, lane, rank, sound, loudness) {
  let at = sounding_voice(effect, lane);
  if (at >= 0 && start_release(mix_voices[at])) at = -1;
  if (at < 0) at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) at = lowest_ranked_voice_below(rank);
  if (at < 0) {
    record_drop();
    return 0;
  }

  start_voice(at, rg_game_note_sounds[sound], rg_game_note_sounds[sound + 1], rg_game_note_sounds[sound + 2], loudness,
    rg_game_note_sounds, sound + 3);
  mix_voices[at].owner = effect < 0 ? SONG : EFFECT;
  mix_voices[at].effect = effect;
  mix_voices[at].lane = lane;
  mix_voices[at].rank = rank;
  spu_recording_struck(at, 0);
  return 1;
}

function rg_mix_release_music(effect, lane) {
  const at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  if (!start_release(mix_voices[at])) mix_voices[at].sounding = 0;
  return 1;
}

function rg_mix_release_all_music() {
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.owner !== SONG || releasing(voice)) continue;
    if (!start_release(voice)) voice.sounding = 0;
  }
}

function rg_mix_rescale_music(lane, loudness) {
  const at = sounding_voice(-1, lane);
  if (at < 0) return 0;
  mix_voices[at].loudness = loudness;
  if (!mix_voices[at].shaped) mix_voices[at].gain = loudness << LOUDNESS_TO_GAIN();
  return 1;
}

function rg_mix_stop(recording) {
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (voice.sounding && voice.owner === GAME && (recording < 0 || voice.recording === recording)) {
      voice.sounding = 0;
      spu_recording_stopped_by_game(i);
    }
  }
  rg_sound_log("stop_sample");
}

/* Each voice told to the sound chip that plays recordings on voices of its own (rg_mix.c says when). */
function rg_mix_recordings_told() {
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    spu_tell_recording(i, voice.sounding, voice.recording, voice.back, voice.step, voice.loudness, voice.level);
  }
}

/* One voice's frame into the totals. Nought when its recording ran out partway and it stopped. */
function mix_voice_into(voice, totals) {
  const numbers = recording_numbers(voice.recording);
  const data = rg_game_recordings[numbers];
  const length = rg_game_recordings[numbers + 1];
  const step_shift = STEP_SHIFT(), step_mask = (1 << step_shift) - 1;
  const whole = voice.step >> step_shift;
  const part = voice.step & step_mask;
  const down = 2 ** (VOL_SHIFT() + GAIN_FRACTION());
  const full_depth = FULL_DEPTH_SHIFT();
  const high_scale = 2 ** full_depth;
  let gain = SHAPES() ? voice.gain : voice.loudness << LOUDNESS_TO_GAIN();
  for (let at = 0; at < SLICE_SAMPLES(); at++) {
    const place = data + voice.position;
    const sample = full_depth ? rg_game_recording_samples[place] * high_scale + rg_game_recording_low_bytes[place] : rg_game_recording_samples[place];
    totals[at] += Math.floor((gain * sample) / down);
    gain = (gain + voice.ramp) | 0;
    voice.fraction += part;
    voice.position += whole + (voice.fraction >> step_shift);
    voice.fraction &= step_mask;
    if (voice.position < length) continue;
    if (voice.back === 0) return 0;

    while (voice.position >= length) voice.position -= voice.back;
    if (voice.owner === GAME) rg_sound_log(`sample ${voice.recording}`);
  }
  voice.gain = gain;
  return 1;
}

function rg_mix_sound_frame() {
  if (!MIXES()) return;
  if (!slice) slice = new Int32Array(SLICE_SAMPLES());

  slice.fill(0);
  for (let i = 0; i < VOICES(); i++) {
    if (mix_voices[i].sounding && !mix_voice_into(mix_voices[i], slice)) mix_voices[i].sounding = 0;
  }
  const highest = (128 << FULL_DEPTH_SHIFT()) - 1;
  for (let at = 0; at < SLICE_SAMPLES(); at++) {
    if (slice[at] > highest) slice[at] = highest;
    if (slice[at] < -highest - 1) slice[at] = -highest - 1;
  }
  slices_made++;
}

/* --- shapes --- */

function step_shape(voice) {
  switch (voice.phase) {
    case CLIMBING: {
      const climbed = voice.level + voice.attack;
      if (climbed >= SHAPE_FULL()) {
        voice.level = SHAPE_FULL();
        voice.phase = HOLDING;
      } else {
        voice.level = climbed;
      }
      break;
    }
    case HOLDING:
      if (voice.level > voice.sustain) {
        const fallen = (voice.level * voice.decay) >> SHAPE_SCALE();
        voice.level = fallen > voice.sustain ? fallen : voice.sustain;
      }
      break;
    default: voice.level = (voice.level * voice.release) >> SHAPE_SCALE(); break;
  }
}

function nearest_whole_gain(gain) {
  return (gain + (1 << (GAIN_FRACTION() - 1))) & ~((1 << GAIN_FRACTION()) - 1);
}

function slide_gain(voice, first) {
  const level = voice.level;
  const target = ((voice.loudness * (level + (level >> 7))) >> WHOLE_GAIN_SHIFT()) << GAIN_FRACTION();
  voice.gain = first ? target : nearest_whole_gain(voice.gain);
  voice.ramp = (((target - voice.gain) >> RAMP_SPLIT()) * SLIDE_SHARE()) >> RAMP_SPLIT();
}

function rg_mix_sound_frame_ended() {
  record_peak();
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || !voice.shaped) continue;
    if (voice.phase === DONE) {
      voice.sounding = 0;
      continue;
    }

    const first = voice.phase === CLIMBING && voice.level === 0;
    step_shape(voice);
    if (voice.level === 0 && voice.phase === FALLING) voice.phase = DONE;
    slide_gain(voice, first);
  }
}

/* --- what a test reads back --- */

function rg_mix_slices_made() { return slices_made; }

/* The newest slice (rg_hook_mixed_slice): its samples, or null before the first. +samples+ is the C signature's out-parameter and is not used here. */
function rg_mix_mixed_slice(samples) { return slices_made > 0 ? slice : null; }

/* rg_hook_mixed_sample_shift (rg_mix.c's rg_mix_mixed_sample_shift). */
function rg_mix_mixed_sample_shift() { return FULL_DEPTH_SHIFT(); }

function rg_mix_voice_count() { return VOICES(); }

/* What voice +voice+ is playing, or null when it is not sounding. */
function rg_mix_voice_sounding(voice) {
  const sounding = mix_voices[voice];
  if (!sounding.sounding) return null;
  return { recording: sounding.recording, loudness: sounding.loudness, level: sounding.level, owner: sounding.owner,
    effect: sounding.owner === EFFECT ? sounding.effect : -1, lane: sounding.lane };
}

function rg_mix_peak() { return peak; }
function rg_mix_drops() { return [drops, drops_music]; }

/* How many slices a windowless run has printed, so each is printed once. */
let slices_printed = 0;

/* rg_hook_moment_printed, asked only by the windowless run (rg_headless.js): the newest slice
 * when it is new, every sounding voice, the most that sounded at once and the plays dropped. A
 * game that declares a recording but mixes nothing prints nothing. */
function rg_mix_moment_printed() {
  if (!rg_game_mix[0]) return;

  if (rg_mix_slices_made() > slices_printed) {
    headless_print(`mix${Array.from(rg_mix_mixed_slice(null), (sample) => ` ${sample}`).join("")}\n`);
    slices_printed = rg_mix_slices_made();
  }
  let mixing_line = "mixing";
  for (let voice = 0; voice < rg_mix_voice_count(); voice++) {
    const reading = rg_mix_voice_sounding(voice);
    if (!reading) continue;
    mixing_line += ` ${reading.recording} ${reading.loudness} ${reading.level} ${reading.owner} ${reading.effect} ${reading.lane}`;
  }
  const [dropped, music_held] = rg_mix_drops();
  headless_print(`${mixing_line}\nmix_peak ${rg_mix_peak()}\nmix_drops ${dropped} ${music_held}\n`);
}

/* --- the state image (rg_mix.c says what each field holds) --- */

/* A voice's numbers in the order rg_mix.c's mix_voice keeps them. */
const MIX_VOICE_FIELDS = Object.keys(silent_mix_voice());

/* rg_hook_visit_sound_state (rg_mix.c's rg_mix_visit_sound_state). */
function rg_mix_visit_sound_state() {
  const counts = [slices_made, peak, drops, drops_music, tickets];
  rg_state_numbers("mix", counts);
  [slices_made, peak, drops, drops_music, tickets] = counts;
  slices_printed = slices_made; // the writer's run printed the newest already

  if (VOICES() > VOICES_MOST) rg_fault(`the mixer has ${VOICES()} voices, and the most is ${VOICES_MOST}`);
  const numbers = mix_voices.slice(0, VOICES()).flatMap((voice) => MIX_VOICE_FIELDS.map((field) => voice[field]));
  rg_state_numbers("mix.voices", numbers);
  for (let i = 0; i < VOICES(); i++) {
    const voice = silent_mix_voice();
    MIX_VOICE_FIELDS.forEach((field, k) => { voice[field] = numbers[i * MIX_VOICE_FIELDS.length + k]; });
    if (voice.sounding && (voice.recording < 0 || voice.recording >= rg_game_recordings[0] || voice.position < 0)) {
      rg_state_refuse_damaged("the mixer plays a recording the game does not have");
    }
    mix_voices[i] = voice;
  }

  const samples = MIXES() ? SLICE_SAMPLES() : 0;
  if (!slice) slice = new Int32Array(Math.max(samples, 1));
  const newest = Array.from(slice.subarray(0, samples));
  rg_state_numbers("mix.slice", newest);
  slice.set(newest);
}

/* --- a recording's settings in the file (rg_mix.h says what each of these is handed) --- */

const RG_FILE_NUMBER_NUMBERS = 4;

/* The number of a recording's setting, from the four numbers of +rules+ at +where+ (rg_mix.c's
 * start_file_setting). */
function rg_start_file_setting(rules, where) {
  const width = rules[where + 1];
  const number = rg_start_file_number(rules[where], width, rules[where + 2]);
  const top = 2 ** (width * 8 - 1);
  return rules[where + 3] && number >= top ? number - top * 2 : number;
}

/* rg_mix.c's number_of_halves. */
function rg_number_of_halves(high, low) {
  const view = new DataView(new ArrayBuffer(8));
  view.setInt32(0, high);
  view.setInt32(4, low);
  return view.getFloat64(0);
}

function rg_mix_fill_steps(into, rules) {
  const rate = Math.max(rg_start_file_setting(rules, 0), 1);
  const rest = RG_FILE_NUMBER_NUMBERS;
  const mix_rate = rg_number_of_halves(rules[rest], rules[rest + 1]);
  const count = rules[rest + 2];
  for (let i = 0; i < count; i++) {
    const entry = rest + 3 + i * 3;
    const step = ((rate / mix_rate) * rg_number_of_halves(rules[entry + 1], rules[entry + 2])) * 65536;
    into[rules[entry]] = step >= 2147483647 ? 2147483647 : step < 1 ? 1 : Math.floor(step + 0.5);
  }
}

/* rg_mix.c's start_file_no_hold. */
function rg_start_file_no_hold(rules, where) {
  const width = rules[where + 1];
  return rg_start_file_number(rules[where], width, rules[where + 2]) === 2 ** (width * 8) - 1;
}

/* rg_mix.c's start_file_back. */
function rg_start_file_back(holds_from, none, length, whole) {
  if (none) return whole ? length : 0;
  return length - Math.min(Math.max(holds_from, 0), length - 1);
}

function rg_mix_fill_holds(into, rules) {
  const rest = RG_FILE_NUMBER_NUMBERS;
  const length = rules[rest], whole = rules[rest + 1], count = rules[rest + 2];
  const back = rg_start_file_back(rg_start_file_setting(rules, 0), rg_start_file_no_hold(rules, 0), length, whole);
  for (let i = 0; i < count; i++) into[rules[rest + 3 + i]] = back;
}

/* rg_mix.c's start_file_length. */
function rg_start_file_length(rules) {
  return Math.min(Math.max(rg_start_file_setting(rules, 0), 1), rules[RG_FILE_NUMBER_NUMBERS]);
}

function rg_mix_fill_length(into, rules) {
  const rest = RG_FILE_NUMBER_NUMBERS + 1;
  const length = rg_start_file_length(rules);
  for (let i = 0; i < rules[rest]; i++) into[rules[rest + 1 + i]] = length;
}

function rg_mix_fill_backs(into, rules) {
  const length = rg_start_file_length(rules);
  const hold = RG_FILE_NUMBER_NUMBERS + 1;
  const rest = hold + 1 + RG_FILE_NUMBER_NUMBERS + 1;
  const from_file = rules[hold] !== 0;
  const holds_from = from_file ? rg_start_file_setting(rules, hold + 1) : rules[hold + 1 + RG_FILE_NUMBER_NUMBERS];
  const none = from_file ? rg_start_file_no_hold(rules, hold + 1) : holds_from < 0;
  const back = rg_start_file_back(holds_from, none, length, rules[rest]);
  for (let i = 0; i < rules[rest + 1]; i++) into[rules[rest + 2 + i]] = back;
}

function rg_mix_fill_shapes(into, rules) {
  const at = rules[0], full = rules[2], count = rules[3];
  const attack = rg_start_file[at], decay = rg_start_file[at + 1], sustain = rg_start_file[at + 2], release = rg_start_file[at + 3];
  const shaped = !(attack === full && sustain === full && release === 0);
  for (let i = 0; i < count; i++) {
    const shape = rules[4 + i];
    into[shape] = shaped ? 1 : 0;
    into[shape + 1] = shaped ? attack : 0;
    into[shape + 2] = shaped ? decay : 0;
    into[shape + 3] = shaped ? sustain : 0;
    into[shape + 4] = shaped ? release : 0;
  }
}
