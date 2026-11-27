/*
 * The music player, the sound effects and the pitch wobble, swell and shape stepping that only notes do. A port of the
 * JavaScript runtime's rg_music.js, function for function (rg_music.c says every rule and the layout of rg_game_music
 * and rg_game_effects). A runtime feature (backends/runtime_features.rb), joined into the script after rg_sound.hx for
 * a game that plays a tune or a sound effect, so it reads the sound runtime's own voices as if it were written there.
 *
 * Its share of the sound runtime's hooks: the frame (sound_frame, after the mixer's slice is made if the game has the
 * mix feature), a voice the game's own beep, wave or stop_wave took (voice_taken_by_game), and a windowless run printing
 * a moment (moment_printed).
 *
 * A song's notes on a recording are sounded by the mixer, when the game has the mix feature: a recorded part can only
 * exist in a game that has it, so a game with music and no recordings builds without the mixer, and these hooks then
 * answer that nothing is sounding.
 *
 * Left out: a part that reads its notes from the start file (rg_music_fill_*).
 */

static inline var PARTS_MOST:Int = 20;
static inline var NUMBERS_PER_NOTE:Int = 6;
static inline var PART_SQUARE:Int = 0;
static inline var PART_WAVE:Int = 1;
static inline var PART_NOISE:Int = 2;
static inline var PART_RECORDED:Int = 3;
static function SONG_COUNT():Int { return rg_game_music[0]; }
static inline var SONG_STARTS:Int = 1;
static inline var NUMBERS_PER_SONG:Int = 5;
static inline var NUMBERS_PER_PART:Int = 6;
static function EFFECT_COUNT():Int { return rg_game_effects[0]; }
static function NOTES_PUT_IN_WAVEFORMS():Int { return rg_game_effects[1]; }
static function EFFECT_CLOCK_STEP():Int { return rg_game_effects[2]; } // what the effects' timer adds a frame, 0 for none
// A note's sixth number: set on a drum hit that says whether it rattles, its noise bits above; set on a wave note that
// names a waveform of its own, that waveform's number above (rg_music.c's).
static inline var HAS_NOISE_BITS:Int = 1 << 11;
static inline var NOISE_BITS_AT:Int = 12;
static inline var NOISE_BITS:Int = 0xF;
static inline var HAS_WAVE:Int = 1 << 16;
static inline var WAVE_AT:Int = 17;
static function EFFECT_TEMPO_STEP():Int { return rg_game_effects[3]; } // what the tempo adds on each interrupt, 0 for none
static function EFFECTS_CUT_NOTES():Int { return rg_game_effects[4]; } // 1 where an effect's note takes its part's own voice
static inline var EFFECT_ROWS:Int = 5;
static inline var NUMBERS_PER_EFFECT:Int = 6;
static inline var EFFECT_SONG:Int = 0;
static inline var EFFECT_NOTES:Int = 1;
static inline var EFFECT_RANK:Int = 2;
static inline var EFFECT_GROUP:Int = 3;
static inline var EFFECT_PRIORITY:Int = 4;
static inline var EFFECT_KEEPS_VOICES:Int = 5;
static inline var EFFECTS_MOST:Int = 512;

/* --- the player --- */

static var wanted:Int = -1;
static var playing:Int = -1;
static var ended:Int = -1;
static var stops:Int = 0;
static var stops_seen:Int = 0;
static var music_held:Bool = false; // the game called hold_music: the tune stays where it is

static var song:Int = 0; /* where the playing song's numbers start in rg_game_music */
static var song_frame:Int = 0;
static var part_count:Int = 0;
static var parts:Array<RgPartWalk> = [for (i in 0...PARTS_MOST) null];

static var level_variable:Void->Int = null; /* reads the game's music volume, for a game that keeps one */
static var level:Int = -1;

static var holding:Array<RgHeldNote> = [];

static function rg_music_request(number:Int):Void {
  if (number < 0 || number >= SONG_COUNT()) rg_fault("there is no song number " + number);
  wanted = number;
}

static function rg_music_request_one_of(songs:Vector<Int>, count:Int, which:Int):Void {
  if (which >= 0 && which < count) rg_music_request(songs[which]);
}

static function rg_music_stop():Void {
  wanted = -1;
  stops++;
}

// The tune stays where it is, or carries on (Reference::Player#hold).
static function rg_music_hold(held:Int):Void { music_held = held != 0; }

static function rg_music_follow_level(variable:Void->Int):Void { level_variable = variable; }

/* Where song number +number+'s numbers start, from its length on. */
static function song_numbers(number:Int):Int { return rg_game_music[SONG_STARTS + number]; }

/* The part of song number +number+ written at +part+ (a place in rg_game_music), as a walk of its notes. Where the
 * song's next part is written is left in +next_part+, and +squares_met+ counts the square wave parts so far. */
static var next_part:Int = 0;
static var squares_met:Int = 0;

static function read_part(number:Int, part:Int, again:Bool):RgPartWalk {
  var kind = rg_game_music[part];
  var first = rg_game_music[part + 4];
  var after = rg_game_music[part + 5];
  var first_notes = part + NUMBERS_PER_PART;
  var after_notes = first_notes + NUMBERS_PER_NOTE * first;
  var voice = 0;
  if (kind == PART_WAVE) voice = RG_WAVE_VOICE;
  else if (kind == PART_NOISE) voice = RG_NOISE_VOICE;
  else if (kind != PART_RECORDED) voice = ++squares_met;
  if (squares_met > RG_SQUARE_VOICES) {
    rg_fault("song number " + number + " has more parts on the square wave than the " + RG_SQUARE_VOICES + " there are");
  }
  var walk = new RgPartWalk(again ? after_notes : first_notes, again ? after : first, kind, voice,
                            rg_game_music[part + 1], rg_game_music[part + 2], rg_game_music[part + 3]);
  next_part = after_notes + NUMBERS_PER_NOTE * after;
  return walk;
}

static function start_walks(again:Bool):Void {
  var part = song + NUMBERS_PER_SONG;
  squares_met = 0;
  for (i in 0...part_count) {
    parts[i] = read_part(playing, part, again);
    part = next_part;
  }
}

static function scaled_volume(volume:Int):Int { return (volume * level) >> LEVEL_SHIFT(); }

static function wave_quarters_at(volume:Int):Int {
  if (volume < 0) volume = 0;
  if (volume >= VOLUMES) volume = VOLUMES - 1;
  return rg_game_sound_rules[WAVE_QUARTERS + volume];
}

static function log_held_loudness(note:RgHeldNote):Void {
  if (note.voice == 0) rg_sound_log("mixer_loudness " + note.lane + " " + scaled_volume(note.volume));
  else rg_sound_log("loudness " + note.voice + " " + scaled_volume(note.volume));
}

static function hold_note(note:RgHeldNote):Void {
  var at = 0;
  while (at < holding.length && (holding[at].voice != note.voice || (note.voice == 0 && holding[at].lane != note.lane))) at++;
  holding[at] = note;
  log_held_loudness(note);
}

static function follow_level(now:Int):Void {
  if (now == level) return;
  level = now;
  for (note in holding) {
    if (note.volume <= 0) continue;
    if (note.voice == 0 && rg_hook_rescale_music(note.lane, scaled_volume(note.volume)) == 0) continue;
    log_held_loudness(note);
    if (note.voice == 0) continue;
    if (note.voice == RG_WAVE_VOICE) {
      wave_set_loudness(wave_quarters_at(scaled_volume(note.volume)));
    } else {
      square_start(note.voice, note.wave_ticks, note.eighths_high, scaled_volume(note.volume), note.fade, 0);
    }
  }
}

/* --- a pitch that wobbles (rg_sound.c's own section says how) --- */

static var wobbles:Array<RgWobble> = [for (i in 0...RG_WAVE_VOICE + 1) new RgWobble()];

static function note_vibrato(note:Int):Int {
  var flags = rg_game_music[note + 4];
  return (flags & HAS_VIBRATO) != 0 ? (flags >>> VIBRATO_AT) & VIBRATO_BITS : 0;
}

static function wobble_start(voice:Int, note:Int):Void {
  if (voice > RG_WAVE_VOICE) return;
  var vibrato = rg_game_music[note + 1] == 0 ? 0 : note_vibrato(note);
  var was = wobbles[voice];
  if ((vibrato & VIBRATO_FOUR_BITS) == 0) {
    was.vibrato = 0;
    was.steps = 0;
    return;
  }
  var carries = (rg_game_music[note + 5] & CARRIES_VIBRATO) != 0;
  var now = new RgWobble();
  now.vibrato = vibrato;
  now.wait = vibrato >> VIBRATO_AFTER_AT;
  now.left = carries ? was.left : 0;
  now.rising = carries ? was.rising : 0;
  now.ticks = rg_game_music[note + 3];
  wobbles[voice] = now;
}

static function wobble_stop(voice:Int):Void {
  if (voice <= RG_WAVE_VOICE) wobbles[voice].vibrato = 0;
}

static function step_wobbles():Void {
  for (voice in 1...RG_WAVE_VOICE + 1) {
    var moving = wobbles[voice];
    var depth = moving.vibrato & VIBRATO_FOUR_BITS;
    if (depth == 0 || held_still(voice)) continue;
    if (moving.wait > 0) {
      moving.wait--;
      continue;
    }
    if (moving.left == 0) {
      moving.rising = moving.rising != 0 ? 0 : 1;
      moving.left = ((moving.vibrato >> VIBRATO_SPEED_AT) & VIBRATO_FOUR_BITS) + 1; // kept less one
      var steps = moving.rising != 0 ? Std.int((depth + 1) / 2) : -Std.int(depth / 2);
      if (steps != moving.steps) rg_sound_log("wobble " + voice + " " + steps);
      moving.steps = steps;
    }
    moving.left--;
    var count = PITCH_COUNT_TOP - moving.ticks + moving.steps;
    if (count < 0) count = 0;
    if (count > PITCH_COUNT_TOP - 1) count = PITCH_COUNT_TOP - 1;
    if (voice == RG_WAVE_VOICE) {
      if (wave_wave_ticks != 0) wave_wave_ticks = PITCH_COUNT_TOP - count;
    } else if (squares[voice - 1].wave_ticks != 0) {
      squares[voice - 1].slid_ticks = PITCH_COUNT_TOP - count;
    }
  }
}

/* A square note's shapes, by its voice: rg_sound.c's shape_walk. */
static var shapes:Array<RgShapeWalk> = [null, new RgShapeWalk(), new RgShapeWalk()];
static var EIGHTHS_OF_SHAPE:Array<Int> = [1, 2, 4, 6];

static function shape_at(bits:Int, frame:Int):Int { return (bits >> (2 * (frame % 4))) & 3; }

static function note_eighths(part:RgPartWalk, note:Int):Int {
  var flags = rg_game_music[note + 5];
  return (flags & HAS_DUTY) != 0 ? EIGHTHS_OF_SHAPE[shape_at(flags, 0)] : part.tone;
}

static function shape_start(voice:Int, note:Int):Void {
  swell_stop(voice);
  if (voice > RG_SQUARE_VOICES) return;
  var flags = rg_game_music[note + 5];
  var bits = rg_game_music[note + 1] != 0 && (flags & HAS_DUTY) != 0 ? flags & DUTY_BITS : 0;
  var steps = 0;
  for (frame in 1...4) if (shape_at(bits, frame) != shape_at(bits, 0)) steps = 1;
  var walk = new RgShapeWalk();
  walk.bits = bits;
  walk.steps = steps;
  shapes[voice] = walk;
}

static function shape_stop(voice:Int):Void {
  if (voice <= RG_SQUARE_VOICES) shapes[voice].steps = 0;
  swell_stop(voice);
}

/* A song's swelling note held under the music volume, by its voice: rg_sound.c's swell_walk. */
static var swells:Array<RgSwell> = [for (i in 0...RG_NOISE_VOICE + 1) new RgSwell()];

static function swell_stop(voice:Int):Void {
  swells[voice].active = 0;
}

static function swell_strike(voice:Int, swell:RgSwell, volume:Int, fade:Int):Void {
  if (voice == RG_NOISE_VOICE) noise_start(swell.wave_ticks, swell.eighths_high, volume, fade);
  else square_start(voice, swell.wave_ticks, swell.eighths_high, volume, fade, 0);
}

static function swell_start(voice:Int, note:Int, eighths_high:Int, volume:Int, fade:Int):Void {
  if (rg_game_music[note + 1] == 0 || (fade & FADE_UP) == 0 || (fade & FADE_STEP_BITS) == 0) return;
  var swell = new RgSwell();
  swell.active = 1;
  swell.step = fade & FADE_STEP_BITS;
  swell.volume = volume;
  swell.counted = 0;
  swell.swelling = 1;
  swell.wave_ticks = rg_game_music[note + 3];
  swell.eighths_high = eighths_high;
  swells[voice] = swell;
}

/* rg_sound.c's step_swells: each struck again where the music volume sets, then counted a frame. */
static function step_swells():Void {
  var ceiling = (LOUDEST * level) >> LEVEL_SHIFT();
  for (voice in 1...RG_NOISE_VOICE + 1) {
    var swell = swells[voice];
    if (swell.active == 0) continue;
    if (swell.swelling != 0 ? swell.volume >= ceiling && ceiling < LOUDEST : swell.volume > ceiling) {
      swell.volume = ceiling;
      swell.counted = 0;
      swell.swelling = 0;
      rg_sound_log("loudness " + voice + " " + ceiling);
      swell_strike(voice, swell, ceiling, 0);
    } else if (swell.swelling == 0 && swell.volume < ceiling) {
      swell.counted = 0;
      swell.swelling = 1;
      rg_sound_log("loudness " + voice + " " + swell.volume + " " + (FADE_UP | swell.step));
      swell_strike(voice, swell, swell.volume, FADE_UP | swell.step);
    }
    if (swell.swelling == 0 || swell.volume >= LOUDEST) continue;
    swell.counted += COUNTED_A_FRAME();
    while (swell.counted >= swell.step * 256 && swell.volume < LOUDEST) {
      swell.counted -= swell.step * 256;
      swell.volume++;
    }
  }
}

static function step_shapes():Void {
  for (voice in 1...RG_SQUARE_VOICES + 1) {
    var walk = shapes[voice];
    if (walk.steps == 0 || held_still(voice)) continue;
    var now = shape_at(walk.bits, walk.frame);
    if (walk.frame > 0 && now != shape_at(walk.bits, walk.frame - 1)) rg_sound_log("duty " + voice + " " + now);
    squares[voice - 1].eighths_high = EIGHTHS_OF_SHAPE[now];
    walk.frame++;
  }
}

static function silence_voice(voice:Int):Void {
  wobble_stop(voice);
  shape_stop(voice);
  if (voice == RG_WAVE_VOICE) wave_set_loudness(0);
  else if (voice == RG_NOISE_VOICE) noise_start(0, hiss_bits, 0, 0);
  else square_start(voice, 0, 0, 0, 0, 0);
}

static function rest_on(part:RgPartWalk):Void {
  if (part.kind != PART_RECORDED) silence_voice(part.voice);
}

/* --- who holds a console voice --- */

static function ORDER_MASK():Int { return rg_game_sound_rules[WAVE_QUARTERS + VOLUMES]; }
static var holders:Array<Int> = [0, 0, 0, 0, 0];

// Is the note on +voice+ the held tune's? A sound effect on a voice keeps moving.
static function held_still(voice:Int):Bool { return music_held && (holders[voice] & ORDER_MASK()) == 0; }
static var holder_order:Array<Int> = [];

static function claim_voice(voice:Int, rank:Int, sounds:Bool):Bool {
  if (holders[voice] > rank) return false;
  if (holder_order.indexOf(voice) < 0) holder_order.push(voice);
  holders[voice] = sounds ? rank : 0;
  return true;
}

static function note_sounds(kind:Int, pitch:Int, volume:Int, fade:Int):Bool {
  if (pitch == 0) return false;
  if ((fade & FADE_UP) != 0 && (fade & FADE_STEP_BITS) != 0 && (kind == PART_SQUARE || kind == PART_NOISE)) return true;
  if (volume <= 0) return false;
  return kind != PART_WAVE || wave_quarters_at(volume) != 0;
}

static function wave_put_in(which:Int):Void {
  if (which == loaded_waveform) return;
  wave_load(which);
}

static function silence_song():Void {
  rg_sound_log("stop_music");
  for (i in 0...part_count) {
    if (parts[i].kind == PART_RECORDED || (holders[parts[i].voice] & ORDER_MASK()) != 0) continue;
    rest_on(parts[i]);
  }
  for (voice in 1...RG_NOISE_VOICE + 1) {
    if ((holders[voice] & ORDER_MASK()) == 0) holders[voice] = 0;
  }
  holding = [];
  rg_hook_release_all_music();
}

static function switch_to_wanted_song():Bool {
  if (ended >= 0) {
    if (wanted == ended && stops == stops_seen) {
      if (playing >= 0) silence_song();
      playing = -1;
      return false;
    }
    ended = -1;
  }
  if (wanted == playing && stops == stops_seen) return false;

  stops_seen = stops;
  music_held = false;
  if (playing >= 0) silence_song();
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return true;

  song = song_numbers(playing);
  part_count = rg_game_music[song + 4];
  if (part_count > PARTS_MOST) rg_fault("song number " + playing + " has " + part_count + " parts, and the most is " + PARTS_MOST);
  start_walks(false);
  if (NOTES_PUT_IN_WAVEFORMS() != 0) return true;
  for (i in 0...part_count) {
    if (parts[i].kind != PART_WAVE) continue;
    wave_load(parts[i].tone);
    break;
  }
  return true;
}

static function play_recorded_note(part:RgPartWalk, note:Int):Void {
  var pitch = rg_game_music[note + 1];
  var loudness = rg_game_music[note + 2];
  var sound = rg_game_music[note + 3];
  if (pitch == 0 || loudness <= 0) {
    rg_hook_release_music(-1, part.tone);
  } else {
    var numbers = 1 + sound * NUMBERS_PER_NOTE_SOUND;
    var heard_loudness = level_variable != null ? scaled_volume(loudness) : loudness;
    var heard = (rg_game_music[note + 5] & GLIDES) != 0
      ? rg_hook_glide_music_note(-1, part.tone, numbers, (rg_game_music[note + 5] & GLIDE_KEEPS_LOUDNESS) != 0 ? -1 : heard_loudness)
      : rg_hook_start_music_note(-1, part.tone, rg_game_music[song + 3], numbers, heard_loudness, 0);
    if (heard == 0) return;
  }
  rg_sound_log("note " + playing + " " + pitch);
  if (level_variable != null) hold_note(new RgHeldNote(0, part.tone, pitch == 0 ? 0 : loudness, 0, 0, 0));
}

static function note_fade(part:RgPartWalk, note:Int):Int {
  var flags = rg_game_music[note + 4];
  if ((flags & HAS_FADE) != 0) return flags & (FADE_UP | FADE_STEP_BITS);
  return part.kind == PART_NOISE ? part.fade : 0;
}

static function note_slide(note:Int):Int { return (rg_game_music[note + 4] >> SLIDE_AT) & SLIDE_BITS; }

static function note_pan(note:Int):Int { return (rg_game_music[note + 4] >>> PAN_AT) & PAN_BITS; }

// A drum hit's noise bits, and a wave note's waveform: its own where it named one, else its part's.
static function note_noise_bits(part:RgPartWalk, note:Int):Int {
  var own = rg_game_music[note + 5];
  return (own & HAS_NOISE_BITS) != 0 ? (own >> NOISE_BITS_AT) & NOISE_BITS : part.tone;
}

static function note_waveform(part:RgPartWalk, note:Int):Int {
  var own = rg_game_music[note + 5];
  return (own & HAS_WAVE) != 0 ? own >>> WAVE_AT : part.tone;
}

// The log's line for a note on the wave or noise voice, with the waveform or the noise bits after it where the note
// named its own.
static function log_wave_or_noise(what:String, who:Int, part:RgPartWalk, pitch:Int, note:Int):Void {
  var own = rg_game_music[note + 5] & (part.kind == PART_WAVE ? HAS_WAVE : HAS_NOISE_BITS);
  if (own == 0) {
    rg_sound_log(what + " " + who + " " + part.number + " " + pitch);
  } else {
    rg_sound_log(what + " " + who + " " + part.number + " " + pitch + " " + (part.kind == PART_WAVE ? note_waveform(part, note) : note_noise_bits(part, note)));
  }
}

static function log_voice_set(voice:Int, who:Int, pitch:Int, volume:Int, note:Int):Void {
  var flags = rg_game_music[note + 4];
  var pan = note_pan(note);
  var after:Array<Int> = [
    (flags & HAS_FADE) != 0 ? flags & (FADE_UP | FADE_STEP_BITS) : -1,
    (flags & HAS_SLIDE) != 0 ? note_slide(note) : -1,
    (flags & HAS_VIBRATO) != 0 ? note_vibrato(note) | ((rg_game_music[note + 5] & CARRIES_VIBRATO) != 0 ? VIBRATO_CARRIES_LOGGED : 0) : -1,
    pan != 0 ? pan : -1,
    (rg_game_music[note + 5] & HAS_DUTY) != 0 ? rg_game_music[note + 5] & DUTY_BITS : -1];
  while (after.length > 0 && after[after.length - 1] < 0) after.pop();
  var line = "voice " + voice + " " + who + " " + pitch + " " + volume;
  for (number in after) line += " " + number;
  rg_sound_log(line);
}

static function play_note(part:RgPartWalk, note:Int):Void {
  if (part.kind == PART_RECORDED) {
    play_recorded_note(part, note);
    return;
  }

  var pitch = rg_game_music[note + 1];
  var volume = rg_game_music[note + 2];
  var ticks = rg_game_music[note + 3];
  if (!claim_voice(part.voice, rg_game_music[song + 3], note_sounds(part.kind, pitch, volume, note_fade(part, note)))) return;

  var written = pitch == 0 ? 0 : volume;
  var sounded = level_variable != null ? scaled_volume(written) : written;
  var fade = note_fade(part, note);
  rg_sound_log("note " + playing + " " + pitch);
  log_voice_set(part.voice, playing, pitch, volume, note);
  wobble_start(part.voice, note);
  shape_start(part.voice, note);
  sides[part.voice] = note_pan(note);
  if (part.kind == PART_WAVE) {
    if (level_variable != null) hold_note(new RgHeldNote(part.voice, 0, written, 0, 0, 0));
    if (pitch == 0) {
      rg_sound_log("stop_wave");
      rest_on(part);
    } else {
      log_wave_or_noise("part_wave", playing, part, pitch, note);
      if (NOTES_PUT_IN_WAVEFORMS() != 0) wave_put_in(note_waveform(part, note));
      wave_start(ticks, wave_quarters_at(sounded));
      voice_struck(RG_WAVE_VOICE);
    }
  } else if (part.kind == PART_NOISE) {
    if (level_variable != null) rg_sound_log("loudness " + part.voice + " " + sounded);
    if (pitch == 0) {
      rg_sound_log("noise_rest");
      rest_on(part);
    } else {
      log_wave_or_noise("part_noise", playing, part, pitch, note);
      noise_start(ticks, note_noise_bits(part, note), sounded, fade);
      voice_struck(RG_NOISE_VOICE);
      if (level_variable != null) swell_start(part.voice, note, note_noise_bits(part, note), sounded, fade);
    }
  } else {
    // A note that fades, swells or slides by itself is left to it (rg_sound.c's play_note says why).
    if (level_variable != null && ((fade & FADE_STEP_BITS) != 0 || note_slide(note) != 0)) {
      drop_held_note(part.voice);
      rg_sound_log("loudness " + part.voice + " " + sounded);
    } else if (level_variable != null) {
      hold_note(new RgHeldNote(part.voice, 0, written, ticks, note_eighths(part, note), fade));
    }
    square_start(part.voice, ticks, note_eighths(part, note), sounded, fade, note_slide(note));
    if (pitch != 0) voice_struck(part.voice);
    if (level_variable != null && note_slide(note) == 0) swell_start(part.voice, note, note_eighths(part, note), sounded, fade);
  }
}

/* --- sound effects --- */

static var effect_asked:Vector<Int> = new Vector<Int>(EFFECTS_MOST);
static var effect_asked_now:Vector<Int> = new Vector<Int>(EFFECTS_MOST);
static var effect_started_now:Vector<Int> = new Vector<Int>(EFFECTS_MOST); // rg_music.c's
static var effect_stopping:Vector<Int> = new Vector<Int>(EFFECTS_MOST);
static var effect_running:Vector<Int> = new Vector<Int>(EFFECTS_MOST);
static var effect_frame:Vector<Int> = new Vector<Int>(EFFECTS_MOST);
static var effect_cursors:Array<Vector<Int>> = [for (i in 0...EFFECTS_MOST) null];

static function effect_row(effect:Int):Int { return EFFECT_ROWS + effect * NUMBERS_PER_EFFECT; }
static function effect_field(effect:Int, field:Int):Int { return rg_game_effects[effect_row(effect) + field]; }

static function effect_pending(effect:Int):Bool {
  return effect_asked[effect] != 0 || (effect_running[effect] != 0 && effect_stopping[effect] == 0);
}

static function refuse_too_many_effects():Void {
  if (EFFECT_COUNT() > EFFECTS_MOST) rg_fault("the game has " + EFFECT_COUNT() + " sound effects, and the most is " + EFFECTS_MOST);
}

static function request_effect(effect:Int):Void {
  refuse_too_many_effects();
  if (effect_field(effect, EFFECT_GROUP) >= 0) {
    for (other in 0...EFFECT_COUNT()) {
      if (effect_field(other, EFFECT_GROUP) != effect_field(effect, EFFECT_GROUP) || !effect_pending(other)) continue;
      if (effect_field(effect, EFFECT_PRIORITY) < effect_field(other, EFFECT_PRIORITY)) return;
      effect_asked[other] = 0;
      effect_stopping[other] = 1;
      break;
    }
  }
  effect_asked[effect] = 1;
}

static function rg_effect_request_one_of(effects:Vector<Int>, count:Int, which:Int):Void {
  if (which >= 0 && which < count) request_effect(effects[which]);
}

static function drop_held_note(voice:Int):Void { holding = holding.filter(function(note) return note.voice != voice); }

static function finish_effect(effect:Int):Void {
  var number = effect_field(effect, EFFECT_SONG);
  var rank = effect_field(effect, EFFECT_RANK);
  effect_running[effect] = 0;
  for (voice in holder_order) {
    if (holders[voice] != rank) continue;
    holders[voice] = 0;
    rg_sound_log("note " + number + " 0");
    rg_sound_log("voice " + voice + " " + number + " 0 0");
    if (voice == RG_NOISE_VOICE) rg_sound_log("noise_rest");
    if (voice == RG_WAVE_VOICE) rg_sound_log("stop_wave");
    silence_voice(voice);
  }

  var numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  var part = numbers + NUMBERS_PER_SONG;
  squares_met = 0;
  for (i in 0...rg_game_music[numbers + 4]) {
    var walk = read_part(number, part, false);
    part = next_part;
    if (walk.kind == PART_RECORDED && rg_hook_release_music(effect, walk.tone) != 0) rg_sound_log("note " + number + " 0");
  }
}

static function play_effect_note(effect:Int, part:RgPartWalk, note:Int):Void {
  var number = effect_field(effect, EFFECT_SONG);
  var rank = effect_field(effect, EFFECT_RANK);
  var pitch = rg_game_music[note + 1];
  var volume = rg_game_music[note + 2];
  var sounds = note_sounds(part.kind, pitch, volume, note_fade(part, note));

  if (part.kind == PART_RECORDED) {
    var sound = rg_game_music[note + 3];
    var loudness = rg_game_music[note + 2];
    var numbers = 1 + sound * NUMBERS_PER_NOTE_SOUND;
    var was_heard = !sounds ? rg_hook_release_music(effect, part.tone)
      : (rg_game_music[note + 5] & GLIDES) != 0 ? rg_hook_glide_music_note(effect, part.tone, numbers, (rg_game_music[note + 5] & GLIDE_KEEPS_LOUDNESS) != 0 ? -1 : loudness)
        : rg_hook_start_music_note(effect, part.tone, rank, numbers, loudness, EFFECTS_CUT_NOTES());
    if (was_heard != 0) rg_sound_log("note " + number + " " + pitch);
    return;
  }
  if (!claim_voice(part.voice, rank, sounds || effect_field(effect, EFFECT_KEEPS_VOICES) == 1)) return;

  var ticks = rg_game_music[note + 3];
  var fade = note_fade(part, note);
  drop_held_note(part.voice);
  rg_sound_log("note " + number + " " + pitch);
  log_voice_set(part.voice, number, pitch, volume, note);
  wobble_start(part.voice, note);
  shape_start(part.voice, note);
  sides[part.voice] = note_pan(note);
  if (part.kind == PART_WAVE) {
    if (pitch == 0) {
      rg_sound_log("stop_wave");
      silence_voice(part.voice);
    } else {
      log_wave_or_noise("part_wave", number, part, pitch, note);
      wave_put_in(note_waveform(part, note));
      wave_start(ticks, wave_quarters_at(volume));
      voice_struck(RG_WAVE_VOICE);
    }
  } else if (part.kind == PART_NOISE) {
    if (pitch == 0) {
      rg_sound_log("noise_rest");
      silence_voice(part.voice);
    } else {
      log_wave_or_noise("part_noise", number, part, pitch, note);
      noise_start(ticks, note_noise_bits(part, note), volume, fade);
      voice_struck(RG_NOISE_VOICE);
    }
  } else {
    square_start(part.voice, ticks, note_eighths(part, note), pitch == 0 ? 0 : volume, fade, note_slide(note));
    if (pitch != 0) voice_struck(part.voice);
  }
}

static function play_effect_frame(effect:Int):Void {
  var number = effect_field(effect, EFFECT_SONG);
  var numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  if (effect_stopping[effect] != 0) {
    effect_stopping[effect] = 0;
    finish_effect(effect);
  }
  if (effect_asked_now[effect] != 0) {
    effect_running[effect] = 1;
    effect_frame[effect] = 0;
    effect_cursors[effect] = new Vector<Int>(PARTS_MOST);
    rg_sound_log("sound_effect " + effect);
  } else if (effect_running[effect] != 0 && effect_frame[effect] >= rg_game_music[numbers]) {
    finish_effect(effect);
  }
  if (effect_running[effect] == 0) return;

  var part_total = rg_game_music[numbers + 4];
  if (part_total > PARTS_MOST) rg_fault("a sound effect has " + part_total + " parts, and the most is " + PARTS_MOST);
  var part = numbers + NUMBERS_PER_SONG;
  squares_met = 0;
  var cursors = effect_cursors[effect];
  for (i in 0...part_total) {
    var walk = read_part(number, part, false);
    part = next_part;
    if (cursors[i] >= walk.count) continue;
    var note = walk.notes + NUMBERS_PER_NOTE * cursors[i];
    if (rg_game_music[note] != effect_frame[effect]) continue;
    cursors[i]++;
    play_effect_note(effect, walk, note);
  }
  effect_frame[effect]++;
}

/* --- the frame --- */

static function effects_by_rank():Int { return EFFECT_ROWS + EFFECT_COUNT() * NUMBERS_PER_EFFECT; }

// The sound effects' timer (rg_music.c's step_effect_clock).
static var effect_clock:Int = 0;

static var effect_tempo:Int = 0;
static var tick_on_first_interrupt:Int = 0;

// rg_music.c's count_ticks_on_interrupts.
static function count_ticks_on_interrupts(interrupts:Int):Int {
  var ticks = 0;
  tick_on_first_interrupt = 0;
  for (at in 0...interrupts) {
    effect_tempo += EFFECT_TEMPO_STEP();
    if ((effect_tempo >> 16) != 0) {
      ticks++;
      if (at == 0) tick_on_first_interrupt = 1;
    }
    effect_tempo &= 0xFFFF;
  }
  return ticks;
}

static function step_effect_clock():Int {
  if (EFFECT_CLOCK_STEP() == 0) return 1;
  effect_clock += EFFECT_CLOCK_STEP();
  var ticks = effect_clock >> 16;
  effect_clock &= 0xFFFF;
  return EFFECT_TEMPO_STEP() != 0 ? count_ticks_on_interrupts(ticks) : ticks;
}

// rg_music.c's skips_started_effects_first_tick.
static function skips_started_effects_first_tick():Bool { return EFFECT_TEMPO_STEP() == 0 || tick_on_first_interrupt != 0; }

// Each effect asked for since the last tick, taken up for the tick playing now.
static function move_asked_effects_to_tick():Void {
  for (effect in 0...EFFECT_COUNT()) {
    effect_asked_now[effect] = effect_asked[effect];
    effect_asked[effect] = 0;
  }
}

// One side of the tune in the frame's first pass over the effects (rg_music.c's play_effects_first_pass).
static function play_effects_first_pass(by_rank:Int, from:Int, to:Int, ticks:Int):Void {
  if (EFFECT_CLOCK_STEP() == 0) {
    for (at in from...to) play_effect_frame(rg_game_effects[by_rank + at]);
    return;
  }
  for (at in from...to) {
    var effect = rg_game_effects[by_rank + at];
    effect_started_now[effect] = effect_asked_now[effect];
    if (effect_asked_now[effect] != 0 || effect_stopping[effect] != 0) play_effect_frame(effect);
    effect_asked_now[effect] = 0;
  }
  var at = from;
  while (ticks > 0 && at < to) {
    var effect = rg_game_effects[by_rank + at];
    if (effect_started_now[effect] == 0 || !skips_started_effects_first_tick()) play_effect_frame(effect);
    at++;
  }
}

static function rg_music_sound_frame():Void {
  if (level < 0) level = FULL_LEVEL();
  refuse_too_many_effects();
  switch_to_wanted_song();
  var ticks = step_effect_clock();
  move_asked_effects_to_tick();
  var tune = playing >= 0 ? rg_game_music[song + 3] : -1;
  var by_rank = effects_by_rank();
  var at = 0;
  while (at < EFFECT_COUNT() && effect_field(rg_game_effects[by_rank + at], EFFECT_RANK) > tune) at++;
  play_effects_first_pass(by_rank, 0, at, ticks);
  if (playing >= 0) play_song_frame();
  play_effects_first_pass(by_rank, at, EFFECT_COUNT(), ticks);
  for (tick in 1...ticks) {
    move_asked_effects_to_tick();
    for (each in 0...EFFECT_COUNT()) {
      var effect = rg_game_effects[by_rank + each];
      if (effect_started_now[effect] == 0 || EFFECT_TEMPO_STEP() != 0) play_effect_frame(effect);
    }
  }
  step_swells();
  step_wobbles();
  step_shapes();
}

static function rg_music_start_here():Void {
  if (level < 0) level = FULL_LEVEL();
  if (switch_to_wanted_song() && playing >= 0) play_song_frame();
}

static function rg_effect_start_here_one_of(effects:Vector<Int>, count:Int, which:Int):Void {
  if (which < 0 || which >= count) return;
  var asked = effects[which];
  request_effect(asked);
  if (effect_asked[asked] == 0) return;

  var by_rank = effects_by_rank();
  for (at in 0...EFFECT_COUNT()) {
    var effect = rg_game_effects[by_rank + at];
    if (effect == asked) {
      effect_asked[asked] = 0;
      effect_asked_now[asked] = 1;
      play_effect_frame(asked);
      effect_asked_now[asked] = 0;
    } else if (effect_stopping[effect] != 0) {
      effect_stopping[effect] = 0;
      finish_effect(effect);
    }
  }
}

static function rg_music_start_here_one_of(songs:Vector<Int>, count:Int, which:Int):Void {
  if (which < 0 || which >= count) return;
  rg_music_request(songs[which]);
  rg_music_start_here();
}

static function play_song_frame():Void {
  if (level_variable != null) follow_level(level_variable());
  if (music_held) return;
  for (i in 0...part_count) {
    var part = parts[i];
    if (part.next >= part.count) continue;
    var note = part.notes + NUMBERS_PER_NOTE * part.next;
    if (rg_game_music[note] != song_frame) continue;

    play_note(part, note);
    part.next++;
  }

  song_frame++;
  if (song_frame < rg_game_music[song]) return;
  if (rg_game_music[song + 2] != 0) {
    ended = playing;
    return;
  }
  song_frame = rg_game_music[song + 1];
  start_walks(true);
}

/* The game's own beep, wave or stop_wave took +voice+ (Reference::Player#game_sound_on): a song's note there no longer
 * wobbles or steps its shapes. */
static function rg_music_voice_taken_by_game(voice:Int):Void {
  wobble_stop(voice);
  shape_stop(voice);
}

/* rg_hook_moment_printed, asked only by the windowless run (rg_headless.hx): the tune the player is on, by the number
 * the log names it by, -1 for none (Reference#music_playing). */
static function rg_music_moment_printed():Void {
  headless_print("music_playing " + playing);
}

/* --- the state image (rg_music.c says what each field holds) --- */

// Where each number sits among the "music" field's.
static inline var MUSIC_AT_ENDED:Int = 2;
static inline var MUSIC_AT_HELD:Int = 5;
static inline var MUSIC_AT_SONG_FRAME:Int = 6;
static inline var MUSIC_AT_LEVEL:Int = 7;
static inline var MUSIC_AT_HOLDING_COUNT:Int = 8;
static inline var MUSIC_AT_HOLDER_COUNT:Int = 9;
static inline var MUSIC_AT_EFFECT_CLOCK:Int = 10;

static inline var PART_STATE_NUMBERS:Int = 2;
static inline var HELD_NOTE_NUMBERS:Int = 6;
static inline var EFFECT_STATE_NUMBERS:Int = 5 + PARTS_MOST;

/* rg_hook_visit_sound_state (rg_music.c's rg_music_visit_sound_state). */
static function rg_music_visit_sound_state():Void {
  var reading = rg_state_reading();
  var general:Array<Int> = [wanted, playing, ended, stops, stops_seen, music_held ? 1 : 0, song_frame, level, holding.length,
    holder_order.length, effect_clock];
  rg_state_numbers("music", general);
  if (general[0] < -1 || general[0] >= SONG_COUNT() || general[1] < -1 || general[1] >= SONG_COUNT() || general[MUSIC_AT_ENDED] < -1 ||
      general[MUSIC_AT_ENDED] >= SONG_COUNT() || general[MUSIC_AT_HOLDING_COUNT] < 0 || general[MUSIC_AT_HOLDING_COUNT] > PARTS_MOST ||
      general[MUSIC_AT_HOLDER_COUNT] < 0 || general[MUSIC_AT_HOLDER_COUNT] > RG_NOISE_VOICE) {
    rg_state_refuse_damaged("the music holds more than it can");
  }
  wanted = general[0];
  playing = general[1];
  ended = general[2];
  stops = general[3];
  stops_seen = general[4];
  music_held = general[MUSIC_AT_HELD] != 0;
  song_frame = general[MUSIC_AT_SONG_FRAME];
  level = general[MUSIC_AT_LEVEL];
  effect_clock = general[MUSIC_AT_EFFECT_CLOCK];

  if (reading) {
    song = playing >= 0 ? song_numbers(playing) : 0;
    part_count = playing >= 0 ? rg_game_music[song + 4] : 0;
    if (part_count > PARTS_MOST) rg_state_refuse_damaged("the song has more parts than a song can");
  }
  var walks:Array<Int> = [];
  if (reading) {
    for (i in 0...part_count * PART_STATE_NUMBERS) walks.push(0);
  } else {
    squares_met = 0;
    var written = song + NUMBERS_PER_SONG;
    for (i in 0...part_count) {
      var first = read_part(playing, written, false);
      written = next_part;
      walks.push(parts[i].notes != first.notes || parts[i].count != first.count ? 1 : 0);
      walks.push(parts[i].next);
    }
  }
  rg_state_numbers("music.parts", walks);
  if (reading) {
    squares_met = 0;
    var written = song + NUMBERS_PER_SONG;
    for (i in 0...part_count) {
      var walk = read_part(playing, written, walks[i * PART_STATE_NUMBERS] != 0);
      written = next_part;
      var at = walks[i * PART_STATE_NUMBERS + 1];
      if (at < 0 || at > walk.count) rg_state_refuse_damaged("a part of the song is past its last note");
      walk.next = at;
      parts[i] = walk;
    }
  }

  var held:Array<Int> = [];
  if (reading) {
    for (i in 0...general[MUSIC_AT_HOLDING_COUNT] * HELD_NOTE_NUMBERS) held.push(0);
  } else {
    for (note in holding) {
      for (number in [note.voice, note.lane, note.volume, note.wave_ticks, note.eighths_high, note.fade]) held.push(number);
    }
  }
  rg_state_numbers("music.holding", held);
  holding = [];
  for (i in 0...general[MUSIC_AT_HOLDING_COUNT]) {
    var at = i * HELD_NOTE_NUMBERS;
    if (held[at] < 0 || held[at] > RG_NOISE_VOICE) rg_state_refuse_damaged("a held note is on a voice there is not");
    holding.push(new RgHeldNote(held[at], held[at + 1], held[at + 2], held[at + 3], held[at + 4], held[at + 5]));
  }

  var voices:Array<Int> = [];
  for (v in 1...RG_WAVE_VOICE + 1) {
    var w = wobbles[v];
    for (number in [w.vibrato, w.wait, w.left, w.rising, w.steps, w.ticks]) voices.push(number);
  }
  for (v in 1...RG_NOISE_VOICE + 1) {
    var s = swells[v];
    for (number in [s.active, s.step, s.volume, s.counted, s.swelling, s.wave_ticks, s.eighths_high]) voices.push(number);
  }
  for (v in 1...RG_SQUARE_VOICES + 1) {
    for (number in [shapes[v].bits, shapes[v].frame, shapes[v].steps]) voices.push(number);
  }
  for (v in 1...RG_NOISE_VOICE + 1) voices.push(holders[v]);
  for (i in 0...RG_NOISE_VOICE) voices.push(i < holder_order.length ? holder_order[i] : 0);
  rg_state_numbers("music.voices", voices);
  var at = 0;
  for (v in 1...RG_WAVE_VOICE + 1) {
    var w = new RgWobble();
    w.vibrato = voices[at];
    w.wait = voices[at + 1];
    w.left = voices[at + 2];
    w.rising = voices[at + 3];
    w.steps = voices[at + 4];
    w.ticks = voices[at + 5];
    wobbles[v] = w;
    at += 6;
  }
  for (v in 1...RG_NOISE_VOICE + 1) {
    var s = new RgSwell();
    s.active = voices[at];
    s.step = voices[at + 1];
    s.volume = voices[at + 2];
    s.counted = voices[at + 3];
    s.swelling = voices[at + 4];
    s.wave_ticks = voices[at + 5];
    s.eighths_high = voices[at + 6];
    swells[v] = s;
    at += 7;
  }
  for (v in 1...RG_SQUARE_VOICES + 1) {
    var shape = new RgShapeWalk();
    shape.bits = voices[at];
    shape.frame = voices[at + 1];
    shape.steps = voices[at + 2];
    shapes[v] = shape;
    at += 3;
  }
  for (v in 1...RG_NOISE_VOICE + 1) holders[v] = voices[at + v - 1];
  holder_order = [];
  for (i in 0...general[MUSIC_AT_HOLDER_COUNT]) {
    var voice = voices[at + RG_NOISE_VOICE + i];
    if (voice < 1 || voice > RG_NOISE_VOICE) rg_state_refuse_damaged("a voice is held that there is not");
    holder_order.push(voice);
  }

  var effects:Array<Int> = [];
  for (e in 0...EFFECT_COUNT()) {
    for (number in [effect_asked[e], effect_asked_now[e], effect_stopping[e], effect_running[e], effect_frame[e]]) effects.push(number);
    for (p in 0...PARTS_MOST) effects.push(effect_cursors[e] != null ? effect_cursors[e][p] : 0);
  }
  rg_state_numbers("music.effects", effects);
  for (e in 0...EFFECT_COUNT()) {
    var base = e * EFFECT_STATE_NUMBERS;
    effect_asked[e] = effects[base] != 0 ? 1 : 0;
    effect_asked_now[e] = effects[base + 1] != 0 ? 1 : 0;
    effect_stopping[e] = effects[base + 2] != 0 ? 1 : 0;
    effect_running[e] = effects[base + 3] != 0 ? 1 : 0;
    effect_frame[e] = effects[base + 4];
    var cursors = new Vector<Int>(PARTS_MOST);
    for (p in 0...PARTS_MOST) cursors[p] = effects[base + 5 + p];
    effect_cursors[e] = cursors;
  }
}
