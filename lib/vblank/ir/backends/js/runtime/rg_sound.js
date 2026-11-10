/*
 * THE GAME'S SOUND: the console's four voices, the sounds the game makes itself, and the log of
 * what was played. A port of the native runtime's rg_sound.c, function for function; that file
 * says every rule of the voices and the layout of every array the lowering writes (rg_game_beeps,
 * ...), and this one reads them the same way. Where the C keeps a pointer into one of those
 * arrays, this keeps the place in it.
 *
 * The music player (runtime_features/music/rg_music.js) and the mixer of recordings
 * (runtime_features/mix/rg_mix.js) are runtime features, joined into the script after this file
 * for a game that plays a tune or a recording. This file reaches them only through the
 * rg_hook_sound_frame, rg_hook_sound_frame_ended, rg_hook_voice_taken_by_game and
 * rg_hook_mixed_slice hooks (backends/runtime_features.rb).
 *
 * The voices are worked out here sample by sample, whatever the driver does with them: the
 * windowless one writes them to a file for a test, and a page hands them to the browser to play.
 */

const RG_SOUND_RATE = 48000;
const RG_SOUND_FRAME_MOST = 1024;
const RG_SQUARE_VOICES = 2;
const RG_WAVE_VOICE = 3;
const RG_NOISE_VOICE = 4;

const FADE_STEP_BITS = 7, FADE_UP = 8, HAS_FADE = 16;
const HAS_SLIDE = 32, SLIDE_AT = 6, SLIDE_BITS = 0x7F, SLIDE_DOWN = 8, SLIDE_SHIFT_BITS = 7, SLIDE_EVERY_AT = 4, SLIDE_EVERY_BITS = 7;
const PITCH_COUNT_TOP = 2048;
const HAS_VIBRATO = 1 << 13, VIBRATO_AT = 14, VIBRATO_BITS = 0xFFFF, VIBRATO_FOUR_BITS = 0xF;
const VIBRATO_SPEED_AT = 4, VIBRATO_AFTER_AT = 8;
const PAN_AT = 30, PAN_BITS = 3, PAN_LEFT = 1, PAN_RIGHT = 2;
const HAS_DUTY = 1 << 8, DUTY_BITS = 0xFF;
const CARRIES_VIBRATO = 1 << 9, VIBRATO_CARRIES_LOGGED = 1 << 16; // a vibrato that carries its swing on, and its bit in the log
const GLIDES = 1 << 10; // a recorded note that carries on the one sounding
const NUMBERS_PER_NOTE_SOUND = 8;
const NUMBERS_PER_BEEP = 4;
const NUMBERS_PER_WAVE = 3;
const NUMBERS_PER_HIT = 4;
const BEEP_VOICE = 2;
const WAVE_STEPS = 32;
const VOLUMES = 16;


function SQUARE_CLOCK_HZ() { return rg_game_sound_rules[0]; }
function WAVE_CLOCK_HZ() { return rg_game_sound_rules[1]; }
function NOISE_CLOCK_HZ() { return rg_game_sound_rules[2]; }
function OUTPUT_HZ() { return rg_game_sound_rules[3]; }
function FULL_LEVEL() { return rg_game_sound_rules[4]; }
function LEVEL_SHIFT() { return rg_game_sound_rules[5]; }
const WAVE_QUARTERS = 6;
function COUNTED_A_FRAME() { return rg_game_sound_rules[WAVE_QUARTERS + VOLUMES + 1]; }
const LOUDEST = VOLUMES - 1;

const STEP_SIZE = 1092;
const MIX_STEP = 128;

/* --- a loudness that fades --- */

function volume_from(volume, fade) {
  const hold = Math.trunc(((fade & FADE_STEP_BITS) * RG_SOUND_RATE) / 64);
  return { volume, hold_samples: hold, left: hold, up: (fade & FADE_UP) !== 0 };
}

function fade_one_sample(fading) {
  if (fading.hold_samples === 0 || --fading.left > 0) return;

  fading.left = fading.hold_samples;
  if (fading.up && fading.volume < VOLUMES - 1) fading.volume++;
  if (!fading.up && fading.volume > 0) fading.volume--;
}

function stays_silent(fading) { return fading.volume === 0 && !fading.up; }

/* --- the square voices --- */

function silent_square() {
  return { wave_ticks: 0, eighths_high: 0, loudness: volume_from(0, 0), eighth: 0, eighth_progress: 0,
           slide: 0, slide_left: 0, slid_ticks: 0 };
}
const squares = [silent_square(), silent_square()];
let heard_only = 0;
let sample_carry = 0;

/* --- a pitch that slides (rg_sound.c's own section says how) --- */

const SLIDE_TICK_SAMPLES = Math.trunc(RG_SOUND_RATE / 128);
let slide_clock = 0;

function slide_step_ticks(slide) { return (slide >> SLIDE_EVERY_AT) & SLIDE_EVERY_BITS; }

function slid_wave_ticks(wave_ticks, slide) {
  const count = PITCH_COUNT_TOP - wave_ticks, by = count >> (slide & SLIDE_SHIFT_BITS);
  const next = slide & SLIDE_DOWN ? count - by : count + by;
  return next >= PITCH_COUNT_TOP ? 0 : PITCH_COUNT_TOP - next;
}

function slide_runs_out(wave_ticks, slide) {
  return (slide & SLIDE_SHIFT_BITS) !== 0 && !(slide & SLIDE_DOWN) && slid_wave_ticks(wave_ticks, slide) === 0;
}

function slide_one_tick(square) {
  if (slide_step_ticks(square.slide) === 0 || square.wave_ticks === 0 || --square.slide_left > 0) return;

  square.slide_left = slide_step_ticks(square.slide);
  if ((square.slide & SLIDE_SHIFT_BITS) === 0) return;

  square.slid_ticks = slid_wave_ticks(square.slid_ticks, square.slide);
  if (square.slid_ticks === 0 || slide_runs_out(square.slid_ticks, square.slide)) square.wave_ticks = 0;
}

/* A voice starts a note where it is in its wave, as the chip does (rg_sound.c's square_start says
 * why). */
function square_start(voice, wave_ticks, eighths_high, volume, fade, slide) {
  const square = squares[voice - 1];
  square.wave_ticks = wave_ticks !== 0 && slide_runs_out(wave_ticks, slide) ? 0 : wave_ticks;
  square.slid_ticks = wave_ticks;
  square.eighths_high = eighths_high;
  square.loudness = volume_from(volume, fade);
  square.slide = slide;
  square.slide_left = slide_step_ticks(slide);
}

function eighth_is_high(eighths_high, eighth) {
  switch (eighths_high) {
    case 1: return eighth === 7;
    case 2: return eighth === 0 || eighth === 7;
    case 4: return eighth === 0 || eighth >= 5;
    default: return eighth >= 1 && eighth <= 6;
  }
}

function square_sample(square) {
  if (square.wave_ticks === 0 || stays_silent(square.loudness)) return 0;

  const high = eighth_is_high(square.eighths_high, square.eighth);
  const sample = Math.trunc((STEP_SIZE * square.loudness.volume * (high ? 8 - square.eighths_high : -square.eighths_high)) / 8);

  let eighth_length = square.wave_ticks * RG_SOUND_RATE;
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

const wave = { steps: new Int32Array(WAVE_STEPS), switched_on: 0, wave_ticks: 0, quarters: 0, cut_sum: 0, step: 0, step_progress: 0 };
let loaded_waveform = -1;

function wave_step_cut(step) { return Math.trunc((step * wave.quarters) / 4); }

function wave_set_loudness(quarters) {
  wave.quarters = quarters;
  wave.cut_sum = 0;
  for (let i = 0; i < WAVE_STEPS; i++) wave.cut_sum += wave_step_cut(wave.steps[i]);
}

function wave_load(which) {
  if (which < 0 || which >= rg_game_waveforms[0]) rg_fault(`there is no waveform number ${which}`);
  for (let i = 0; i < WAVE_STEPS; i++) wave.steps[i] = rg_game_waveforms[1 + which * WAVE_STEPS + i];
  loaded_waveform = which;
  wave.switched_on = 1;
  wave.wave_ticks = 0;
  wave_set_loudness(wave.quarters);
}

function wave_start(wave_ticks, quarters) {
  wave.wave_ticks = wave.switched_on ? wave_ticks : 0;
  wave.step = 0;
  wave.step_progress = 0;
  wave_set_loudness(quarters);
}

function wave_switch_off() {
  wave.switched_on = 0;
  wave.wave_ticks = 0;
}

function wave_sample() {
  if (wave.wave_ticks === 0) return 0;

  const sample = Math.trunc((STEP_SIZE * (WAVE_STEPS * wave_step_cut(wave.steps[wave.step]) - wave.cut_sum)) / WAVE_STEPS);

  const step_length = wave.wave_ticks * RG_SOUND_RATE;
  wave.step_progress += WAVE_CLOCK_HZ() * WAVE_STEPS;
  while (wave.step_progress >= step_length) {
    wave.step_progress -= step_length;
    wave.step = (wave.step + 1) % WAVE_STEPS;
  }
  return sample;
}

/* --- the noise voice --- */

const hiss = { step_ticks: 0, bits: 0, row: 0, high: 0, heard_high: 0, loudness: volume_from(0, 0), row_progress: 0, hand_progress: 0 };

function noise_start(step_ticks, bits, volume, fade) {
  hiss.step_ticks = step_ticks;
  hiss.bits = bits;
  hiss.row = (2 ** bits - 1) >>> 0;
  hiss.high = 0;
  hiss.heard_high = 0;
  hiss.loudness = volume_from(volume, fade);
  hiss.row_progress = 0;
  hiss.hand_progress = 0;
}

function noise_step() {
  const fell = hiss.row & 1;
  hiss.row >>>= 1;
  if (fell) hiss.row = (hiss.row ^ (3 << (hiss.bits - 2))) >>> 0;
  hiss.high = fell;
}

function noise_sample() {
  if (hiss.step_ticks === 0 || stays_silent(hiss.loudness)) return 0;

  hiss.hand_progress += OUTPUT_HZ();
  while (hiss.hand_progress >= RG_SOUND_RATE) {
    hiss.hand_progress -= RG_SOUND_RATE;
    const step_length = hiss.step_ticks * OUTPUT_HZ();
    hiss.row_progress += NOISE_CLOCK_HZ();
    while (hiss.row_progress >= step_length) {
      hiss.row_progress -= step_length;
      noise_step();
    }
    hiss.heard_high = hiss.high;
  }
  const sample = Math.trunc((STEP_SIZE * hiss.loudness.volume * (hiss.heard_high ? 1 : -1)) / 2);
  fade_one_sample(hiss.loudness);
  return sample;
}

/* --- the sound of a frame --- */

function rg_sound_hear_only(voice) { heard_only = voice; }

function heard(voice, sample) { return heard_only === 0 || heard_only === voice ? sample : 0; }

/* Which speaker each console voice plays from, by its number: PAN_LEFT, PAN_RIGHT, or 0 for both. */
const sides = [0, 0, 0, 0, 0];

function held_in_range(sum) { return Math.max(-32768, Math.min(32767, sum)); }

/* The sound of the frame that has just been played, the left speaker's written into +left+ and the
 * right's into +right+ (Int16Arrays with room for RG_SOUND_FRAME_MOST); gives back how many each. */
function rg_sound_render_frame(left, right) {
  sample_carry += RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME;
  const count = Math.floor(sample_carry / RG_CONSOLE_TICKS_A_SECOND);
  sample_carry %= RG_CONSOLE_TICKS_A_SECOND;

  const mixed = heard_only === 0 ? rg_hook_mixed_slice(null) : null;
  const mixed_count = mixed ? mixed.length : 0;

  for (let i = 0; i < count; i++) {
    if (++slide_clock === SLIDE_TICK_SAMPLES) {
      slide_clock = 0;
      for (let voice = 1; voice <= RG_SQUARE_VOICES; voice++) slide_one_tick(squares[voice - 1]);
    }
    let on_left = 0, on_right = 0;
    const add_to_sides = (voice, sample) => {
      if (sides[voice] !== PAN_RIGHT) on_left += sample;
      if (sides[voice] !== PAN_LEFT) on_right += sample;
    };
    for (let voice = 1; voice <= RG_SQUARE_VOICES; voice++) add_to_sides(voice, heard(voice, square_sample(squares[voice - 1])));
    add_to_sides(RG_WAVE_VOICE, heard(RG_WAVE_VOICE, wave_sample()));
    add_to_sides(RG_NOISE_VOICE, heard(RG_NOISE_VOICE, noise_sample()));
    if (mixed_count > 0) {
      const sample = mixed[Math.trunc((i * mixed_count) / count)] * MIX_STEP;
      on_left += sample;
      on_right += sample;
    }
    left[i] = held_in_range(on_left);
    right[i] = held_in_range(on_right);
  }
  return count;
}

/* --- the log --- */

function rg_sound_log(line) { rg_active_driver.sound_logged(line); }

/* --- the sounds the game makes itself --- */

function rg_sound_enabled() {
  rg_sound_log("enabled");
  sides.fill(0);
}

function rg_sound_beep(which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault(`there is no beep number ${which}`);
  const beep = 1 + which * NUMBERS_PER_BEEP;
  rg_sound_log(`beep ${which}`);
  rg_hook_voice_taken_by_game(BEEP_VOICE);
  sides[BEEP_VOICE] = 0;
  square_start(BEEP_VOICE, rg_game_beeps[beep], rg_game_beeps[beep + 1], rg_game_beeps[beep + 2], rg_game_beeps[beep + 3], 0);
}

function rg_sound_wave(which) {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault(`there is no wave number ${which}`);
  const said = 1 + which * NUMBERS_PER_WAVE;
  rg_sound_log(`wave ${which}`);
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  sides[RG_WAVE_VOICE] = 0;
  wave_load(rg_game_waves[said]);
  wave_start(rg_game_waves[said + 1], rg_game_waves[said + 2]);
  loaded_waveform = -1;
}

function rg_sound_stop_wave() {
  rg_sound_log("stop_wave");
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  wave_switch_off();
  loaded_waveform = -1;
}

/* The frame's sound work, in the interpreter's order (Reference#advance_frame): each sound
 * feature's frame (the mix's slice, then the tune), then what follows the tune (the mixer's
 * shapes). Called where the frame begins; this file names no feature. */
function rg_sound_frame() {
  rg_hook_sound_frame();
  rg_hook_sound_frame_ended();
}

function rg_sound_noise(which) {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault(`there is no hit number ${which}`);
  const hit = 1 + which * NUMBERS_PER_HIT;
  rg_sound_log(`noise ${which}`);
  sides[RG_NOISE_VOICE] = 0;
  noise_start(rg_game_hits[hit], rg_game_hits[hit + 1], rg_game_hits[hit + 2], rg_game_hits[hit + 3]);
}

/* --- the state image (rg_sound.c says what each field holds) --- */

function loudness_numbers(fading) { return [fading.volume, fading.hold_samples, fading.left, fading.up ? 1 : 0]; }

function loudness_from(n) {
  if (n[0] < 0 || n[0] >= VOLUMES) rg_state_refuse_damaged("a voice is louder than a voice can be");
  return { volume: n[0], hold_samples: n[1], left: n[2], up: n[3] !== 0 };
}

const LOUDNESS_NUMBERS = 4; // A loudness as four numbers: now, samples it holds a step, samples left, whether it swells
const SQUARE_LOUDNESS_AT = 7; // Where a square's loudness starts among its numbers, which end with it
const NOISE_LOUDNESS_AT = 7; // Where the noise voice's loudness starts among its numbers, which end with it
const SQUARE_STATE_NUMBERS = SQUARE_LOUDNESS_AT + LOUDNESS_NUMBERS;
const EIGHTH_HIGHEST = 7; // The highest eighth of a square's wave
const NOISE_BITS_FEWEST = 2; // The fewest bits the noise's row can hold
const NOISE_BITS_MOST = 31; // The most bits the noise's row can hold

function rg_sound_visit_state() {
  const general = [sample_carry, slide_clock, loaded_waveform, sides[1], sides[2], sides[3], sides[4]];
  rg_state_numbers("sound", general);
  if (general[0] < 0 || general[0] >= RG_CONSOLE_TICKS_A_SECOND || general[1] < 0 || general[1] >= SLIDE_TICK_SAMPLES ||
      general[2] < -1 || general[2] >= rg_game_waveforms[0]) rg_state_refuse_damaged("the sound is somewhere it cannot be");
  [sample_carry, slide_clock, loaded_waveform] = general;
  for (let voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    const side = general[2 + voice];
    if (side !== 0 && side !== PAN_LEFT && side !== PAN_RIGHT) rg_state_refuse_damaged("a voice plays from a speaker there is not");
    sides[voice] = side;
  }

  const square_numbers = squares.flatMap((s) => [s.wave_ticks, s.eighths_high, s.eighth, s.eighth_progress, s.slide, s.slide_left,
    s.slid_ticks, ...loudness_numbers(s.loudness)]);
  rg_state_numbers("sound.squares", square_numbers);
  squares.forEach((_, i) => {
    const n = square_numbers.slice(i * SQUARE_STATE_NUMBERS, (i + 1) * SQUARE_STATE_NUMBERS);
    if (n[2] < 0 || n[2] > EIGHTH_HIGHEST || n[0] < 0 || n[6] < 0) rg_state_refuse_damaged("a square voice is part way through a wave it cannot be");
    squares[i] = { wave_ticks: n[0], eighths_high: n[1], loudness: loudness_from(n.slice(SQUARE_LOUDNESS_AT)), eighth: n[2], eighth_progress: n[3],
      slide: n[4], slide_left: n[5], slid_ticks: n[6] };
  });

  const wave_numbers = [...wave.steps, wave.switched_on, wave.wave_ticks, wave.quarters, wave.cut_sum, wave.step, wave.step_progress];
  rg_state_numbers("sound.wave", wave_numbers);
  const rest = wave_numbers.slice(WAVE_STEPS);
  if (rest[4] < 0 || rest[4] >= WAVE_STEPS || rest[1] < 0) rg_state_refuse_damaged("the wave voice is on a step it does not have");
  wave.steps.set(wave_numbers.slice(0, WAVE_STEPS));
  [wave.switched_on, wave.wave_ticks, wave.quarters, wave.cut_sum, wave.step, wave.step_progress] = rest;
  wave.switched_on = wave.switched_on !== 0 ? 1 : 0;

  const noise_numbers = [hiss.step_ticks, hiss.bits, hiss.row, hiss.high, hiss.heard_high, hiss.row_progress, hiss.hand_progress,
    ...loudness_numbers(hiss.loudness)];
  rg_state_numbers("sound.noise", noise_numbers);
  if (noise_numbers[0] < 0 || (noise_numbers[0] !== 0 && (noise_numbers[1] < NOISE_BITS_FEWEST || noise_numbers[1] > NOISE_BITS_MOST)) || noise_numbers[2] < 0 ||
      noise_numbers[2] > 0xFFFFFFFF) rg_state_refuse_damaged("the noise voice holds a row of bits it cannot");
  [hiss.step_ticks, hiss.bits, hiss.row, hiss.high, hiss.heard_high, hiss.row_progress, hiss.hand_progress] = noise_numbers;
  hiss.loudness = loudness_from(noise_numbers.slice(NOISE_LOUDNESS_AT));

  rg_hook_visit_sound_state();
}

