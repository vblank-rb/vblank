/*
 * The mixer: several recordings sounding at once, added together a frame at a time into one stream of sound, the way
 * the console's own software mixer does it. A port of the JavaScript runtime's rg_mix.js, function for function; the
 * native runtime's rg_mix.c says the arithmetic and the layout of rg_game_mix and rg_game_recordings, and this one
 * keeps both to the bit. A product too big for 32 bits is worked out as a float, which holds it exactly, and brought
 * down by rounding down, as the C's 64-bit shift does.
 *
 * A runtime feature (backends/runtime_features.rb), joined into the class after rg_sound.hx for a game that declares a
 * recording; it takes the sound_frame, sound_frame_ended, mixed_slice and mixed_sample_shift hooks.
 *
 * Left out: a recording's settings read from the start file (rg_mix_fill_*), the Super Nintendo chip's envelope and its
 * recordings in the chip's own format, and the state image.
 */

static inline var VOICES_MOST:Int = 16;
static inline var NUMBERS_PER_RECORDING:Int = 7;

static function MIXES():Int { return rg_game_mix[0]; }
static function SLICE_SAMPLES():Int { return rg_game_mix[1]; }
static function SHAPES():Int { return rg_game_mix[2]; }
static function SLIDE_SHARE():Int { return rg_game_mix[3]; }
static function VOICES():Int { return rg_game_mix[4]; }
static function VOL_SHIFT():Int { return rg_game_mix[5]; }
static function STEP_SHIFT():Int { return rg_game_mix[6]; }
static function GAIN_FRACTION():Int { return rg_game_mix[7]; }
static function RAMP_SPLIT():Int { return rg_game_mix[8]; }
static function SHAPE_FULL():Int { return rg_game_mix[9]; }
static function SHAPE_SCALE():Int { return rg_game_mix[10]; }
static function LOUDNESS_TO_GAIN():Int { return rg_game_mix[11]; }
static function WHOLE_GAIN_SHIFT():Int { return rg_game_mix[12]; }
static function FULL_DEPTH_SHIFT():Int { return rg_game_mix[13]; }

static inline var CLIMBING:Int = 0;
static inline var HOLDING:Int = 1;
static inline var FALLING:Int = 2;
static inline var DONE:Int = 3;
static inline var GAME:Int = 0;
static inline var SONG:Int = 1;
static inline var EFFECT:Int = 2;

static var mix_voices:Array<RgMixVoice> = [for (i in 0...VOICES_MOST) new RgMixVoice()];
static var slice:Vector<Int> = null;
static var slices_made:Int = 0;
static var peak:Int = 0;
static var drops:Int = 0;
static var drops_music:Int = 0;
static var tickets:Int = 0;

/* The sound chip that plays recordings on voices of its own is told which struck and stopped; a console whose voices
 * are worked out here has none. */
static function spu_recording_struck(place:Int, by_game:Int):Void {}
static function spu_recording_stopped_by_game(place:Int):Void {}

/* Where recording number +recording+'s numbers start in rg_game_recordings. */
static function recording_numbers(recording:Int):Int {
  if (recording < 0 || recording >= rg_game_recordings[0]) rg_fault("there is no recording number " + recording);
  return 1 + recording * NUMBERS_PER_RECORDING;
}

static function voices_sounding():Int {
  var count = 0;
  for (i in 0...VOICES()) count += mix_voices[i].sounding;
  return count;
}

static function record_peak():Void {
  var now = voices_sounding();
  if (now > peak) peak = now;
}

static function record_drop():Void {
  var music = 0;
  for (i in 0...VOICES()) music += mix_voices[i].sounding != 0 && mix_voices[i].owner != GAME ? 1 : 0;
  drops++;
  if (music > drops_music) drops_music = music;
}

static function free_voice():Int {
  if (VOICES() > VOICES_MOST) rg_fault("the mixer has " + VOICES() + " voices, and the most is " + VOICES_MOST);
  for (i in 0...VOICES()) {
    if (mix_voices[i].sounding == 0) return i;
  }
  return -1;
}

static function releasing(voice:RgMixVoice):Bool { return voice.owner != GAME && (voice.phase == FALLING || voice.phase == DONE); }

static function quietest_releasing_voice():Int {
  var found = -1;
  for (i in 0...VOICES()) {
    if (mix_voices[i].sounding == 0 || !releasing(mix_voices[i])) continue;
    if (found < 0 || mix_voices[i].level < mix_voices[found].level) found = i;
  }
  return found;
}

static function lowest_ranked_voice_below(rank:Int):Int {
  var found = -1;
  for (i in 0...VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding == 0 || voice.rank >= rank) continue;
    if (found >= 0) {
      var best = mix_voices[found];
      if (voice.rank > best.rank) continue;
      if (voice.rank == best.rank && (voice.loops > best.loops || (voice.loops == best.loops && voice.ticket >= best.ticket))) continue;
    }
    found = i;
  }
  return found;
}

/* A voice at the top of +recording+, shaped by the five numbers of +shape+ from +at+ (whether it has one, then its
 * four numbers). */
static function start_voice(voice_at:Int, recording:Int, step:Int, back:Int, loudness:Int, shape:Vector<Int>, at:Int):Void {
  recording_numbers(recording);
  var shaped = shape[at];
  var voice = new RgMixVoice();
  voice.sounding = 1;
  voice.owner = GAME;
  voice.rank = -1;
  voice.recording = recording;
  voice.step = step;
  voice.back = back;
  voice.loudness = loudness;
  voice.gain = shaped != 0 ? 0 : loudness << LOUDNESS_TO_GAIN();
  voice.shaped = shaped;
  voice.level = shaped != 0 ? 0 : SHAPE_FULL();
  voice.phase = CLIMBING;
  voice.attack = shape[at + 1];
  voice.decay = shape[at + 2];
  voice.sustain = shape[at + 3];
  voice.release = shape[at + 4];
  mix_voices[voice_at] = voice;
}

/* A sound the game plays with a shape takes its shape's first step as it is played, its gain at that level with no
 * slide. */
static function step_shape_at_start(voice:RgMixVoice):Void {
  step_shape(voice);
  slide_gain(voice, true);
}

static function rg_mix_play(recording:Int, step:Int, loudness:Int, back:Int, loops:Int):Void {
  rg_sound_log("sample " + recording);
  var at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) {
    record_drop();
    return;
  }

  start_voice(at, recording, step, back, loudness, rg_game_recordings, recording_numbers(recording) + 2);
  if (mix_voices[at].shaped != 0) step_shape_at_start(mix_voices[at]);
  mix_voices[at].loops = loops;
  mix_voices[at].ticket = ++tickets;
  spu_recording_struck(at, 1);
  record_peak();
}

static function sounding_voice(effect:Int, lane:Int):Int {
  var owner = effect < 0 ? SONG : EFFECT;
  for (i in 0...VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding == 0 || voice.owner != owner || voice.lane != lane || releasing(voice)) continue;
    if (owner == SONG || voice.effect == effect) return i;
  }
  return -1;
}

static function start_release(voice:RgMixVoice):Int {
  if (voice.shaped == 0) return 0;
  voice.phase = FALLING;
  return 1;
}

/* Reference::Mixer#glide_music_note: the note sounding reads on at the row's pitch, at +loudness+, or at its own where
 * that is -1. */
static function rg_mix_glide_music_note(effect:Int, lane:Int, sound:Int, loudness:Int):Int {
  var at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  mix_voices[at].step = rg_game_note_sounds[sound + 1];
  if (loudness < 0) return 1;
  mix_voices[at].loudness = loudness;
  if (mix_voices[at].shaped == 0) mix_voices[at].gain = loudness << LOUDNESS_TO_GAIN();
  return 1;
}

/* +sound+ is where the note's eight numbers start in rg_game_note_sounds. */
static function owned_voice(effect:Int, lane:Int):Int {
  var at = sounding_voice(effect, lane);
  var i = 0;
  while (at < 0 && i < VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding != 0 && voice.owner == EFFECT && voice.effect == effect && voice.lane == lane) at = i;
    i++;
  }
  return at;
}

static function rg_mix_start_music_note(effect:Int, lane:Int, rank:Int, sound:Int, loudness:Int, cuts:Int):Int {
  var cutting = cuts != 0 && effect >= 0;
  var at = cutting ? owned_voice(effect, lane) : sounding_voice(effect, lane);
  if (at >= 0 && !cutting && start_release(mix_voices[at]) != 0) at = -1;
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

static function rg_mix_release_music(effect:Int, lane:Int):Int {
  var at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  if (start_release(mix_voices[at]) == 0) mix_voices[at].sounding = 0;
  return 1;
}

static function rg_mix_release_all_music():Void {
  for (i in 0...VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding == 0 || voice.owner != SONG || releasing(voice)) continue;
    if (start_release(voice) == 0) voice.sounding = 0;
  }
}

static function rg_mix_rescale_music(lane:Int, loudness:Int):Int {
  var at = sounding_voice(-1, lane);
  if (at < 0) return 0;
  mix_voices[at].loudness = loudness;
  if (mix_voices[at].shaped == 0) mix_voices[at].gain = loudness << LOUDNESS_TO_GAIN();
  return 1;
}

static function rg_mix_stop(recording:Int):Void {
  for (i in 0...VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding != 0 && voice.owner == GAME && (recording < 0 || voice.recording == recording)) {
      voice.sounding = 0;
      spu_recording_stopped_by_game(i);
    }
  }
  rg_sound_log("stop_sample");
}

/* Each voice told to the sound chip that plays recordings on voices of its own: only a console whose voices read
 * sound memory asks, and the Flash build refuses a game that makes sound on one. */
static function rg_mix_recordings_told():Void {}

/* One voice's frame into the totals. Nought when its recording ran out partway and it stopped. */
static function mix_voice_into(voice:RgMixVoice, totals:Vector<Int>):Int {
  var numbers = recording_numbers(voice.recording);
  var data = rg_game_recordings[numbers];
  var length = rg_game_recordings[numbers + 1];
  var step_shift = STEP_SHIFT();
  var step_mask = (1 << step_shift) - 1;
  var whole = voice.step >> step_shift;
  var part = voice.step & step_mask;
  var down:Float = Math.pow(2, VOL_SHIFT() + GAIN_FRACTION());
  var full_depth = FULL_DEPTH_SHIFT();
  var high_scale = 1 << full_depth;
  var gain = SHAPES() != 0 ? voice.gain : voice.loudness << LOUDNESS_TO_GAIN();
  for (at in 0...SLICE_SAMPLES()) {
    var place = data + voice.position;
    var sample = full_depth != 0 ? rg_game_recording_samples[place] * high_scale + rg_game_recording_low_bytes[place] : rg_game_recording_samples[place];
    totals[at] += Std.int(rg_floor((gain * 1.0 * sample) / down));
    gain = (gain + voice.ramp) | 0;
    voice.fraction += part;
    voice.position += whole + (voice.fraction >> step_shift);
    voice.fraction &= step_mask;
    if (voice.position < length) continue;
    if (voice.back == 0) return 0;

    while (voice.position >= length) voice.position -= voice.back;
    if (voice.owner == GAME) rg_sound_log("sample " + voice.recording);
  }
  voice.gain = gain;
  return 1;
}

static function rg_mix_sound_frame():Void {
  if (MIXES() == 0) return;
  if (slice == null) slice = new Vector<Int>(SLICE_SAMPLES());

  for (at in 0...SLICE_SAMPLES()) slice[at] = 0;
  for (i in 0...VOICES()) {
    if (mix_voices[i].sounding != 0 && mix_voice_into(mix_voices[i], slice) == 0) mix_voices[i].sounding = 0;
  }
  var highest = (128 << FULL_DEPTH_SHIFT()) - 1;
  for (at in 0...SLICE_SAMPLES()) {
    if (slice[at] > highest) slice[at] = highest;
    if (slice[at] < -highest - 1) slice[at] = -highest - 1;
  }
  slices_made++;
}

/* --- shapes --- */

static function step_shape(voice:RgMixVoice):Void {
  switch (voice.phase) {
    case CLIMBING:
      var climbed = voice.level + voice.attack;
      if (climbed >= SHAPE_FULL()) {
        voice.level = SHAPE_FULL();
        voice.phase = HOLDING;
      } else {
        voice.level = climbed;
      }
    case HOLDING:
      if (voice.level > voice.sustain) {
        var fallen = (voice.level * voice.decay) >> SHAPE_SCALE();
        voice.level = fallen > voice.sustain ? fallen : voice.sustain;
      }
    default: voice.level = (voice.level * voice.release) >> SHAPE_SCALE();
  }
}

static function nearest_whole_gain(gain:Int):Int {
  return (gain + (1 << (GAIN_FRACTION() - 1))) & ~((1 << GAIN_FRACTION()) - 1);
}

static function slide_gain(voice:RgMixVoice, first:Bool):Void {
  var level = voice.level;
  var target = ((voice.loudness * (level + (level >> 7))) >> WHOLE_GAIN_SHIFT()) << GAIN_FRACTION();
  voice.gain = first ? target : nearest_whole_gain(voice.gain);
  voice.ramp = (((target - voice.gain) >> RAMP_SPLIT()) * SLIDE_SHARE()) >> RAMP_SPLIT();
}

static function rg_mix_sound_frame_ended():Void {
  record_peak();
  for (i in 0...VOICES()) {
    var voice = mix_voices[i];
    if (voice.sounding == 0 || voice.shaped == 0) continue;
    if (voice.phase == DONE) {
      voice.sounding = 0;
      continue;
    }

    var first = voice.phase == CLIMBING && voice.level == 0;
    step_shape(voice);
    if (voice.level == 0 && voice.phase == FALLING) voice.phase = DONE;
    slide_gain(voice, first);
  }
}

/* --- what a test reads back --- */

static function rg_mix_slices_made():Int { return slices_made; }

/* The newest slice (rg_hook_mixed_slice): its samples put in +samples+, and how many; none before the first. */
static function rg_mix_mixed_slice(samples:Array<Int>):Int {
  if (slices_made == 0) return 0;
  for (at in 0...SLICE_SAMPLES()) samples.push(slice[at]);
  return SLICE_SAMPLES();
}

/* rg_hook_mixed_sample_shift */
static function rg_mix_mixed_sample_shift():Int { return FULL_DEPTH_SHIFT(); }

/* How many slices a windowless run has printed, so each is printed once. */
static var slices_printed:Int = 0;

/* rg_hook_moment_printed, asked only by the windowless run (rg_headless.hx): the newest slice when it is new, every
 * sounding voice, the most that sounded at once and the plays dropped. A game that declares a recording but mixes
 * nothing prints nothing. */
static function rg_mix_moment_printed():Void {
  if (rg_game_mix[0] == 0) return;

  if (slices_made > slices_printed) {
    var newest:Array<Int> = [];
    rg_mix_mixed_slice(newest);
    headless_print("mix" + [for (sample in newest) " " + sample].join(""));
    slices_printed = slices_made;
  }
  var mixing_line = "mixing";
  for (voice_at in 0...VOICES()) {
    var voice = mix_voices[voice_at];
    if (voice.sounding == 0) continue;
    mixing_line += " " + voice.recording + " " + voice.loudness + " " + voice.level + " " + voice.owner + " " +
      (voice.owner == EFFECT ? voice.effect : -1) + " " + voice.lane;
  }
  headless_print(mixing_line + "\nmix_peak " + peak + "\nmix_drops " + drops + " " + drops_music);
}

/* The state image is not written in Flash yet. */
static function rg_mix_visit_sound_state():Void { rg_state_refuse(); }
