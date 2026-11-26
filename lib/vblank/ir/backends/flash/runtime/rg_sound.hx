/*
 * The game's sound: the console's four voices, the sounds the game makes itself, and the log of what was played. A
 * port of the JavaScript runtime's rg_sound.js, function for function; that file and the native runtime's
 * rg_sound.c say every rule of the voices and the layout of every array the lowering writes (rg_game_beeps, ...), and
 * this one reads them the same way.
 *
 * The music player and the mixer of recordings are runtime features, joined in after this file for a game that plays a
 * tune or a recording. This file reaches them only through the rg_hook_sound_frame, rg_hook_sound_frame_ended,
 * rg_hook_voice_taken_by_game and rg_hook_mixed_slice hooks.
 *
 * The voices are worked out here sample by sample, whatever the driver does with them: the headless one hands them to
 * the harness for a test, and a page plays them through a Sound.
 *
 * Left out: a console whose voices read sound memory (RG_VOICES_READ_SOUND_MEMORY, rg_spu.js): a game that makes sound
 * there is refused by name before it is built (Flash::Lowering#text_and_gaps), and the state image.
 */

static inline var RG_SOUND_RATE:Int = 48000;
static inline var RG_SOUND_FRAME_MOST:Int = 1024;
static inline var RG_SQUARE_VOICES:Int = 2;
static inline var RG_WAVE_VOICE:Int = 3;
static inline var RG_NOISE_VOICE:Int = 4;

static inline var FADE_STEP_BITS:Int = 7;
static inline var FADE_UP:Int = 8;
static inline var PITCH_COUNT_TOP:Int = 2048;
static inline var SLIDE_DOWN:Int = 8;
static inline var SLIDE_SHIFT_BITS:Int = 7;
static inline var SLIDE_EVERY_AT:Int = 4;
static inline var SLIDE_EVERY_BITS:Int = 7;
static inline var PAN_LEFT:Int = 1;
static inline var PAN_RIGHT:Int = 2;
static inline var NUMBERS_PER_BEEP:Int = 4;
static inline var NUMBERS_PER_WAVE:Int = 3;
static inline var NUMBERS_PER_HIT:Int = 4;
static inline var BEEP_VOICE:Int = 2;
static inline var WAVE_STEPS:Int = 32;
static inline var VOLUMES:Int = 16;

static function SQUARE_CLOCK_HZ():Int { return rg_game_sound_rules[0]; }
static function WAVE_CLOCK_HZ():Int { return rg_game_sound_rules[1]; }
static function NOISE_CLOCK_HZ():Int { return rg_game_sound_rules[2]; }
static function OUTPUT_HZ():Int { return rg_game_sound_rules[3]; }
static inline var WAVE_QUARTERS:Int = 6;
// The main volume the game named, in 127ths, or -1 for none.
static function MAIN_VOLUME():Int { return rg_game_sound_rules[WAVE_QUARTERS + VOLUMES + 2]; }
static inline var MAIN_VOLUME_LOUDEST:Int = 127;

// The whole mix at the main volume, rounded toward nought.
static function at_main_volume(sum:Int):Int {
  var main_volume = MAIN_VOLUME();
  return main_volume < 0 ? sum : Std.int((sum * main_volume) / MAIN_VOLUME_LOUDEST);
}

static inline var STEP_SIZE:Int = 1092;
static inline var MIX_STEP:Int = 128;

/* The sound chip's voices keep track of which a game struck; a console whose voices are worked out here has none. */
static function game_voice_struck(voice:Int):Void {}
static function spu_slide_started(voice:Int):Void {}
static function spu_waveform_put_in(which:Int):Void {}

/* --- a loudness that fades --- */

static function volume_from(volume:Int, fade:Int):RgLoudness {
  var hold = Std.int(((fade & FADE_STEP_BITS) * RG_SOUND_RATE) / 64);
  return new RgLoudness(volume, hold, hold, (fade & FADE_UP) != 0);
}

static function fade_one_sample(fading:RgLoudness):Void {
  if (fading.hold_samples == 0) return;
  fading.left--;
  if (fading.left > 0) return;

  fading.left = fading.hold_samples;
  if (fading.up && fading.volume < VOLUMES - 1) fading.volume++;
  if (!fading.up && fading.volume > 0) fading.volume--;
}

static function stays_silent(fading:RgLoudness):Bool { return fading.volume == 0 && !fading.up; }

/* --- the square voices --- */

static var squares:Array<RgSquare> = [new RgSquare(), new RgSquare()];
static var heard_only:Int = 0;
static var sample_carry:Float = 0;

/* --- a pitch that slides --- */

static inline var SLIDE_TICK_SAMPLES:Int = 375; // RG_SOUND_RATE / 128
static var slide_clock:Int = 0;

static function slide_step_ticks(slide:Int):Int { return (slide >> SLIDE_EVERY_AT) & SLIDE_EVERY_BITS; }

static function slid_wave_ticks(wave_ticks:Int, slide:Int):Int {
  var count = PITCH_COUNT_TOP - wave_ticks;
  var by = count >> (slide & SLIDE_SHIFT_BITS);
  var next = (slide & SLIDE_DOWN) != 0 ? count - by : count + by;
  return next >= PITCH_COUNT_TOP ? 0 : PITCH_COUNT_TOP - next;
}

static function slide_runs_out(wave_ticks:Int, slide:Int):Bool {
  return (slide & SLIDE_SHIFT_BITS) != 0 && (slide & SLIDE_DOWN) == 0 && slid_wave_ticks(wave_ticks, slide) == 0;
}

static function slide_one_tick(square:RgSquare):Void {
  if (slide_step_ticks(square.slide) == 0 || square.wave_ticks == 0) return;
  square.slide_left--;
  if (square.slide_left > 0) return;

  square.slide_left = slide_step_ticks(square.slide);
  if ((square.slide & SLIDE_SHIFT_BITS) == 0) return;

  square.slid_ticks = slid_wave_ticks(square.slid_ticks, square.slide);
  if (square.slid_ticks == 0 || slide_runs_out(square.slid_ticks, square.slide)) square.wave_ticks = 0;
}

/* A voice starts a note where it is in its wave, as the chip does (rg_sound.c's square_start says why). */
static function square_start(voice:Int, wave_ticks:Int, eighths_high:Int, volume:Int, fade:Int, slide:Int):Void {
  var square = squares[voice - 1];
  square.wave_ticks = wave_ticks != 0 && slide_runs_out(wave_ticks, slide) ? 0 : wave_ticks;
  square.slid_ticks = wave_ticks;
  square.eighths_high = eighths_high;
  square.loudness = volume_from(volume, fade);
  square.slide = slide;
  square.slide_left = slide_step_ticks(slide);
  spu_slide_started(voice);
}

static function eighth_is_high(eighths_high:Int, eighth:Int):Bool {
  switch (eighths_high) {
    case 1: return eighth == 7;
    case 2: return eighth == 0 || eighth == 7;
    case 4: return eighth == 0 || eighth >= 5;
    default: return eighth >= 1 && eighth <= 6;
  }
}

static function square_sample(square:RgSquare):Int {
  if (square.wave_ticks == 0 || stays_silent(square.loudness)) return 0;

  var high = eighth_is_high(square.eighths_high, square.eighth);
  var sample = Std.int((STEP_SIZE * square.loudness.volume * (high ? 8 - square.eighths_high : -square.eighths_high)) / 8);

  var eighth_length = square.wave_ticks * RG_SOUND_RATE;
  square.eighth_progress += SQUARE_CLOCK_HZ() * 8;
  while (square.eighth_progress >= eighth_length) {
    square.eighth_progress -= eighth_length;
    square.eighth = (square.eighth + 1) & 7;
    square.wave_ticks = square.slid_ticks;
    eighth_length = square.wave_ticks * RG_SOUND_RATE;
  }
  fade_one_sample(square.loudness);
  return sample;
}

/* --- the wave voice --- */

static var wave_steps:Vector<Int> = new Vector<Int>(WAVE_STEPS);
static var wave_switched_on:Int = 0;
static var wave_wave_ticks:Int = 0;
static var wave_quarters:Int = 0;
static var wave_cut_sum:Int = 0;
static var wave_step:Int = 0;
static var wave_step_progress:Int = 0;
static var loaded_waveform:Int = -1;

static function wave_step_cut(step:Int):Int { return Std.int((step * wave_quarters) / 4); }

static function wave_set_loudness(quarters:Int):Void {
  wave_quarters = quarters;
  wave_cut_sum = 0;
  for (i in 0...WAVE_STEPS) wave_cut_sum += wave_step_cut(wave_steps[i]);
}

static function wave_load(which:Int):Void {
  if (which < 0 || which >= rg_game_waveforms[0]) rg_fault("there is no waveform number " + which);
  for (i in 0...WAVE_STEPS) wave_steps[i] = rg_game_waveforms[1 + which * WAVE_STEPS + i];
  loaded_waveform = which;
  spu_waveform_put_in(which);
  wave_switched_on = 1;
  wave_wave_ticks = 0;
  wave_set_loudness(wave_quarters);
}

static function wave_start(wave_ticks:Int, quarters:Int):Void {
  wave_wave_ticks = wave_switched_on != 0 ? wave_ticks : 0;
  wave_step = 0;
  wave_step_progress = 0;
  wave_set_loudness(quarters);
}

static function wave_switch_off():Void {
  wave_switched_on = 0;
  wave_wave_ticks = 0;
}

static function wave_sample():Int {
  if (wave_wave_ticks == 0) return 0;

  var sample = Std.int((STEP_SIZE * (WAVE_STEPS * wave_step_cut(wave_steps[wave_step]) - wave_cut_sum)) / WAVE_STEPS);

  var step_length = wave_wave_ticks * RG_SOUND_RATE;
  wave_step_progress += WAVE_CLOCK_HZ() * WAVE_STEPS;
  while (wave_step_progress >= step_length) {
    wave_step_progress -= step_length;
    wave_step = (wave_step + 1) % WAVE_STEPS;
  }
  return sample;
}

/* --- the noise voice --- */

static var hiss_step_ticks:Int = 0;
static var hiss_bits:Int = 0;
static var hiss_row:Int = 0;
static var hiss_high:Int = 0;
static var hiss_heard_high:Int = 0;
static var hiss_loudness:RgLoudness = new RgLoudness(0, 0, 0, false);
static var hiss_row_progress:Int = 0;
static var hiss_hand_progress:Int = 0;

static function noise_start(step_ticks:Int, bits:Int, volume:Int, fade:Int):Void {
  hiss_step_ticks = step_ticks;
  hiss_bits = bits;
  hiss_row = (1 << bits) - 1;
  hiss_high = 0;
  hiss_heard_high = 0;
  hiss_loudness = volume_from(volume, fade);
  hiss_row_progress = 0;
  hiss_hand_progress = 0;
}

static function noise_step():Void {
  var fell = hiss_row & 1;
  hiss_row = hiss_row >>> 1;
  if (fell != 0) hiss_row = hiss_row ^ (3 << (hiss_bits - 2));
  hiss_high = fell;
}

static function noise_sample():Int {
  if (hiss_step_ticks == 0 || stays_silent(hiss_loudness)) return 0;

  hiss_hand_progress += OUTPUT_HZ();
  while (hiss_hand_progress >= RG_SOUND_RATE) {
    hiss_hand_progress -= RG_SOUND_RATE;
    var step_length = hiss_step_ticks * OUTPUT_HZ();
    hiss_row_progress += NOISE_CLOCK_HZ();
    while (hiss_row_progress >= step_length) {
      hiss_row_progress -= step_length;
      noise_step();
    }
    hiss_heard_high = hiss_high;
  }
  var sample = Std.int((STEP_SIZE * hiss_loudness.volume * (hiss_heard_high != 0 ? 1 : -1)) / 2);
  fade_one_sample(hiss_loudness);
  return sample;
}

/* --- the sound of a frame --- */

static function rg_sound_hear_only(voice:Int):Void { heard_only = voice; }

static function heard(voice:Int, sample:Int):Int { return heard_only == 0 || heard_only == voice ? sample : 0; }

/* Which speaker each console voice plays from, by its number: PAN_LEFT, PAN_RIGHT, or 0 for both. */
static var sides:Vector<Int> = new Vector<Int>(5);

static function held_in_range(sum:Int):Int { return sum < -32768 ? -32768 : (sum > 32767 ? 32767 : sum); }

/* The sound of the frame that has just been played, the left speaker's written into +left+ and the right's into
 * +right+ (vectors with room for RG_SOUND_FRAME_MOST); gives back how many each. */
static function rg_sound_render_frame(left:Vector<Int>, right:Vector<Int>):Int {
  sample_carry += RG_SOUND_RATE * 1.0 * RG_CONSOLE_TICKS_A_FRAME;
  var count = Std.int(rg_floor(sample_carry / RG_CONSOLE_TICKS_A_SECOND));
  sample_carry = sample_carry % RG_CONSOLE_TICKS_A_SECOND;

  var mixed:Array<Int> = [];
  var mixed_count = heard_only == 0 ? rg_hook_mixed_slice(mixed) : 0;
  var mixed_shift = rg_hook_mixed_sample_shift();

  for (i in 0...count) {
    slide_clock++;
    if (slide_clock == SLIDE_TICK_SAMPLES) {
      slide_clock = 0;
      for (voice in 1...RG_SQUARE_VOICES + 1) slide_one_tick(squares[voice - 1]);
    }
    var on_left = 0;
    var on_right = 0;
    for (voice in 1...RG_NOISE_VOICE + 1) {
      var made = voice <= RG_SQUARE_VOICES ? square_sample(squares[voice - 1]) : (voice == RG_WAVE_VOICE ? wave_sample() : noise_sample());
      var sample = heard(voice, made);
      if (sides[voice] != PAN_RIGHT) on_left += sample;
      if (sides[voice] != PAN_LEFT) on_right += sample;
    }
    if (mixed_count > 0) {
      var sample = (mixed[Std.int((i * mixed_count) / count)] * MIX_STEP) >> mixed_shift;
      on_left += sample;
      on_right += sample;
    }
    left[i] = held_in_range(at_main_volume(on_left));
    right[i] = held_in_range(at_main_volume(on_right));
  }
  return count;
}

/* --- the log --- */

/* The driver says what a line of the log means (the headless one prints it). */
static function rg_sound_log(line:String):Void { rg_sound_logged(line); }

/* --- the sounds the game makes itself --- */

static function rg_sound_enabled():Void {
  rg_sound_log(MAIN_VOLUME() < 0 ? "enabled" : "enabled " + MAIN_VOLUME());
  for (i in 0...5) sides[i] = 0;
}

static function rg_sound_beep(which:Int):Void {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault("there is no beep number " + which);
  var beep = 1 + which * NUMBERS_PER_BEEP;
  rg_sound_log("beep " + which);
  rg_hook_voice_taken_by_game(BEEP_VOICE);
  sides[BEEP_VOICE] = 0;
  square_start(BEEP_VOICE, rg_game_beeps[beep], rg_game_beeps[beep + 1], rg_game_beeps[beep + 2], rg_game_beeps[beep + 3], 0);
  game_voice_struck(BEEP_VOICE);
}

static function rg_sound_wave(which:Int):Void {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault("there is no wave number " + which);
  var said = 1 + which * NUMBERS_PER_WAVE;
  rg_sound_log("wave " + which);
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  sides[RG_WAVE_VOICE] = 0;
  wave_load(rg_game_waves[said]);
  wave_start(rg_game_waves[said + 1], rg_game_waves[said + 2]);
  game_voice_struck(RG_WAVE_VOICE);
  loaded_waveform = -1;
}

static function rg_sound_stop_wave():Void {
  rg_sound_log("stop_wave");
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  wave_switch_off();
  loaded_waveform = -1;
}

/* The frame's sound work, in the interpreter's order (Reference#advance_frame): each sound feature's frame (the mix's
 * slice, then the tune), then what follows the tune (the mixer's shapes). Called where the frame begins; this file
 * names no feature. */
static function rg_sound_frame():Void {
  rg_hook_sound_frame();
  rg_hook_sound_frame_ended();
}

static function rg_sound_noise(which:Int):Void {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault("there is no hit number " + which);
  var hit = 1 + which * NUMBERS_PER_HIT;
  rg_sound_log("noise " + which);
  sides[RG_NOISE_VOICE] = 0;
  noise_start(rg_game_hits[hit], rg_game_hits[hit + 1], rg_game_hits[hit + 2], rg_game_hits[hit + 3]);
  game_voice_struck(RG_NOISE_VOICE);
}
