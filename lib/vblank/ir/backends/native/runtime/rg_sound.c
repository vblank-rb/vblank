/*
 * The console's four voices, the sounds the game makes itself and the sound log (see rg_sound.h).
 *
 * The music player (the music runtime feature) and the mixer of recordings (the mix runtime
 * feature) are not here: a game that plays no tune or no recording is built without them. They are
 * joined into this file at its end (see the hooks below), and this file calls them only through
 * those hooks.
 *
 * THE VOICES. The console has four of its own, and every rule below is the console's
 * (Audio::Sound has them in one place for every backend, and the lowering writes the numbers
 * here from there).
 *
 * Two play a SQUARE WAVE: a wave that is high for part of its length and low for the rest.
 *
 *   - its PITCH is how many ticks of a 131,072-a-second clock one wave lasts, a whole number;
 *   - its TONE is how many eighths of the wave are high — half is full and hollow, less is
 *     thinner and brighter;
 *   - its LOUDNESS is 0 to 15, and a note that fades loses one of those every so many 64ths of a
 *     second until it is silent.
 *
 * One loops a WAVEFORM: 32 steps of 0 to 15, played one after another and round again, which
 * can be any shape — a triangle, a sine, a pulse of the game's own.
 *
 *   - its PITCH is how many ticks of a 65,536-a-second clock all 32 steps last;
 *   - its LOUDNESS is one of five: so many quarters of each step, none to all four, with what
 *     does not divide dropped. It does not fade; it plays until it is told otherwise.
 *
 * There is one waveform in the voice at a time. A `wave` puts its own there, and so does a tune
 * with a part on this voice, as it starts. `stop_wave` switches the voice off, and it then stays
 * silent whatever notes it is given until one of those two switches it on again.
 *
 * One makes a HISS: a row of bits shuffled along a place at a time, the voice high or low by the
 * bit that falls off the end.
 *
 *   - its PITCH is how many ticks of a 524,288-a-second clock one step lasts — fast is a thin
 *     high hiss, slow a rumble;
 *   - its TONE is how many bits are in the row: fifteen is a plain hiss, and seven comes round
 *     so soon it is heard as a rattle;
 *   - its LOUDNESS is 0 to 15 and fades the way a square voice's does.
 *
 * A song's first square part plays on the first voice and its second on the second, and a note
 * there holds until the next one. A beep plays on the second voice and fades. So a song with two
 * square parts and a beep share that voice, and whichever was started last is what it plays — as
 * on the console. The wave voice is shared the same way by a song's wave part and the game's
 * `wave`, and the noise voice by a song's drums and the game's `noise`.
 *
 * WHAT THE LOWERING WRITES for the voices, all whole numbers.
 *
 * rg_game_sound_rules: the ticks a second of the square voices' clock, the wave voice's and the
 * noise voice's; how many times a second the console hands its voices on to the speaker; then
 * the numbers only the music player reads: the music volume a part sounds at in full and how far
 * to shift back down by it (IR::Tunes::FULL_LEVEL and LEVEL_SHIFT); sixteen numbers, the wave
 * voice's loudness in quarters for each volume from 0 to 15; and the part of a rank that is a
 * sound effect's order (IR::Tunes::ORDER_MASK), nought for the song; and the 256ths of a 64th of
 * a second a frame lasts (IR::Tunes::COUNTED_A_FRAME).
 *
 * rg_game_waveforms: how many waveforms there are, then 32 steps for each.
 *
 * rg_game_beeps: how many beeps there are, then four numbers a beep — the ticks one wave lasts,
 * eighths high, the volume it starts at, and the 64ths of a second it holds each step of volume
 * as it fades (0 never fades).
 *
 * rg_game_waves: how many different things the game tells the wave voice to play, then three
 * numbers each — which waveform, the ticks one wave lasts, and its loudness in quarters.
 *
 * rg_game_hits: how many different hits the game makes on the noise voice, then four numbers
 * each — the ticks one step of the hiss lasts, the bits in its row, the volume it starts at, and
 * the 64ths of a second it holds each step of volume as it fades.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_sound.h"
#include "rg_driver.h"
#include "rg_state.h"
#include "rg_runtime.h"
#include "rg_console.h"

#define NUMBERS_PER_BEEP 4
#define NUMBERS_PER_WAVE 3
#define NUMBERS_PER_HIT 4
#define BEEP_VOICE 2
#define WAVE_STEPS 32
#define VOLUMES 16

/* A note's fade (Audio::NoteFade#bits): the 64ths of a second a step lasts, and set when it swells. */
#define FADE_STEP_BITS 7
#define FADE_UP 8

/* A square note's slide (Audio::PitchSlide#bits): set when it slides down, the shift, and the
 * 128ths of a second a step waits, above them, in three bits. The first square voice keeps its
 * pitch as a count that climbs as the note gets higher: this less the ticks a wave lasts. */
#define SLIDE_DOWN 8
#define SLIDE_SHIFT_BITS 7
#define SLIDE_EVERY_AT 4
#define SLIDE_EVERY_BITS 7
#define PITCH_COUNT_TOP 2048

/* The speaker a voice plays from (Audio::Pan.bits_of): the left alone, the right alone, or nought
 * for both. */
#define PAN_LEFT 1
#define PAN_RIGHT 2

/* Where things are in rg_game_sound_rules (see the layout above). */
#define SQUARE_CLOCK_HZ (rg_game_sound_rules[0])
#define WAVE_CLOCK_HZ (rg_game_sound_rules[1])
#define NOISE_CLOCK_HZ (rg_game_sound_rules[2])
#define OUTPUT_HZ (rg_game_sound_rules[3])

/* --- the hooks a sound feature takes ---
 *
 * The music player and the mixer are runtime features (backends/runtime_features/), and the build
 * includes them at the END of this file only for a game that plays a tune or a recording, so they
 * read this file's own voices. This file calls them only through these, which the same included
 * file defines (RuntimeFeatures::HOOKS says what each is for). A hook no feature takes does what
 * the sound does without one. */
static void rg_hook_sound_frame(void);                           /* the frame begins */
static void rg_hook_sound_frame_ended(void);                     /* ...and what follows the tune's frame */
static void rg_hook_voice_taken_by_game(int32_t voice);          /* a beep, wave or stop_wave took a voice */
static int32_t rg_hook_mixed_slice(const int32_t **samples);     /* the newest mixed slice, or 0 for none */
static void rg_hook_moment_printed(void);                        /* a windowless run prints a moment */
static void rg_hook_visit_sound_state(void);                     /* the state image visits each feature's fields */

/* How much one step of loudness moves the speaker. Two voices at their loudest then swing
 * through half of what a sample can hold. All four at once, at their loudest, can ask for more
 * than a sample holds, and the sum is then held at the end of what it can (see
 * rg_sound_render_frame). */
#define STEP_SIZE 1092

/* How much one step of the mixer's byte moves the speaker: its loudest, 127, is about half of
 * what a sample holds, as two console voices at their loudest are. */
#define MIX_STEP 128

/* A frame is RG_CONSOLE_TICKS_A_FRAME ticks of the console's clock (rg_console.h), as rg_sdl.c
 * has it. A frame's samples are that share of a second's, and the part of a sample left over is
 * carried to the next frame so no time is lost or made up. The clock is not a power of two on
 * every console, so the share is a division. */

/* --- a loudness that fades --- */

/* The loudness of a square voice or the noise voice: 0 to 15 now, and how it fades — or swells,
 * which is the same counting the other way, one step up each time until it is at full. */
typedef struct {
  int32_t volume;       /* 0 to 15, now */
  int32_t hold_samples; /* samples it holds each step of volume for; 0 never fades */
  int32_t left;         /* samples until the next step */
  int32_t up;           /* 1 when it swells */
} fading_volume;

/* +fade+ is the voice's four bits of it (Audio::NoteFade#bits): the 64ths of a second each step
 * lasts, and 8 when it counts up. A fade that only ever counts down is its step alone. */
static fading_volume volume_from(int32_t volume, int32_t fade) {
  int32_t hold = (fade & FADE_STEP_BITS) * RG_SOUND_RATE / 64;
  return (fading_volume){volume, hold, hold, (fade & FADE_UP) != 0};
}

/* One sample has gone by. */
static void fade_one_sample(fading_volume *fading) {
  if (fading->hold_samples == 0 || --fading->left > 0) return;

  fading->left = fading->hold_samples;
  if (fading->up && fading->volume < VOLUMES - 1) fading->volume++;
  if (!fading->up && fading->volume > 0) fading->volume--;
}

/* Is the voice silent for good: at no volume, and not swelling out of it? */
static int32_t stays_silent(const fading_volume *fading) { return fading->volume == 0 && !fading->up; }

/* --- the square voices --- */

typedef struct {
  int32_t wave_ticks;      /* ticks one wave lasts; 0 when the voice has nothing to play */
  int32_t eighths_high;    /* how many eighths of the wave are high */
  fading_volume loudness;
  int32_t eighth;          /* which eighth of the wave it is in */
  int64_t eighth_progress; /* how far through that eighth, in ticks times samples a second */
  int32_t slide;           /* how its pitch slides (Audio::PitchSlide#bits); 0 holds it */
  int32_t slide_left;      /* ticks of the slide clock until the slide's next step */
  int32_t slid_ticks;      /* the wave a slide has moved it to, which it takes up at its next eighth */
} square_voice;

static square_voice squares[RG_SQUARE_VOICES];
static int32_t heard_only; /* a test listening to one voice: its number, or 0 for every voice */
static uint64_t sample_carry; /* the fraction of a sample left over from the last frame */

/* --- a pitch that slides --- */

/* THE SLIDE CLOCK ticks 128 times a second from the moment the sound starts, and a slide steps on
 * every so many of its ticks — the console's own clock, which a note does not start again. So a
 * note's first step comes part way into a tick, as early as the next one. */
#define SLIDE_TICK_SAMPLES (RG_SOUND_RATE / 128)
static int32_t slide_clock; /* samples since the slide clock last ticked */

/* The ticks between two steps of a slide: so many 128ths of a second. */
static int32_t slide_step_ticks(int32_t slide) { return (slide >> SLIDE_EVERY_AT) & SLIDE_EVERY_BITS; }

/* WHERE A STEP OF THE SLIDE TAKES THE PITCH. The first square voice keeps its pitch as a count that
 * climbs as the note gets higher — PITCH_COUNT_TOP less the ticks one wave lasts — and a step moves
 * the count by itself shifted right by the slide's shift, up or down. Past the top of the count
 * there is no pitch to play, and the voice switches itself off: that answers 0. */
static int32_t slid_wave_ticks(int32_t wave_ticks, int32_t slide) {
  int32_t count = PITCH_COUNT_TOP - wave_ticks, by = count >> (slide & SLIDE_SHIFT_BITS);
  int32_t next = slide & SLIDE_DOWN ? count - by : count + by;
  return next >= PITCH_COUNT_TOP ? 0 : PITCH_COUNT_TOP - next;
}

/* THE VOICE LOOKS ONE STEP AHEAD, as the console's does: as a note starts and after every step, it
 * works out the next step up, and a next step past the top switches it off then — so the highest
 * pitch a slide up reaches is never heard. A slide down never runs out. */
static int32_t slide_runs_out(int32_t wave_ticks, int32_t slide) {
  return (slide & SLIDE_SHIFT_BITS) != 0 && !(slide & SLIDE_DOWN) && slid_wave_ticks(wave_ticks, slide) == 0;
}

/* The slide clock has ticked, on a voice whose note slides. A slide with no shift steps without
 * moving. The voice takes a step's new pitch up as it starts its next eighth of a wave, as the chip
 * does: the eighth it is in runs out at the old one. Switching itself off is at once. */
static void slide_one_tick(square_voice *square) {
  if (slide_step_ticks(square->slide) == 0 || square->wave_ticks == 0 || --square->slide_left > 0) return;

  square->slide_left = slide_step_ticks(square->slide);
  if ((square->slide & SLIDE_SHIFT_BITS) == 0) return;

  square->slid_ticks = slid_wave_ticks(square->slid_ticks, square->slide);
  if (square->slid_ticks == 0 || slide_runs_out(square->slid_ticks, square->slide)) square->wave_ticks = 0;
}

/* A voice starts a note where it is in its wave, as the chip does in the emulator the cartridge is
 * checked in: starting a note again leaves its place in the wave alone. A game fading its music
 * starts every held note again each frame, and a voice that went back to the top of its wave each
 * time would break a wave every frame, heard as a rumble under the note. No ticks, or no volume, is
 * silence. +slide+ is how the note slides its pitch (0 holds it), which only a note on the first voice
 * has (Guardrails::Checks::SlideOffFirstSquare). */
static void square_start(int32_t voice, int32_t wave_ticks, int32_t eighths_high, int32_t volume, int32_t fade,
                         int32_t slide) {
  square_voice *square = &squares[voice - 1];
  square->wave_ticks = wave_ticks != 0 && slide_runs_out(wave_ticks, slide) ? 0 : wave_ticks;
  square->slid_ticks = wave_ticks;
  square->eighths_high = eighths_high;
  square->loudness = volume_from(volume, fade);
  square->slide = slide;
  square->slide_left = slide_step_ticks(slide);
}

/* The console's own order of high and low through a wave, for each tone: which of the eight
 * parts are high. (It makes no difference to the ear where in the wave the high part falls.) */
static int32_t eighth_is_high(int32_t eighths_high, int32_t eighth) {
  switch (eighths_high) {
  case 1: return eighth == 7;
  case 2: return eighth == 0 || eighth == 7;
  case 4: return eighth == 0 || eighth >= 5;
  default: return eighth >= 1 && eighth <= 6;
  }
}

/* One sample of a voice. High and low are set either side of nought by how long each lasts, so
 * a wave averages nought whatever its tone and starting or stopping one does not jolt the
 * speaker to one side. */
static int32_t square_sample(square_voice *square) {
  if (square->wave_ticks == 0 || stays_silent(&square->loudness)) return 0;

  int32_t high = eighth_is_high(square->eighths_high, square->eighth);
  int32_t sample = STEP_SIZE * square->loudness.volume * (high ? 8 - square->eighths_high : -square->eighths_high) / 8;

  /* An eighth of a wave lasts wave_ticks / 8 ticks, and a sample lasts the clock's ticks a
   * second over the samples a second: kept as whole numbers by counting in ticks times samples
   * a second. */
  int64_t eighth_length = (int64_t)square->wave_ticks * RG_SOUND_RATE;
  square->eighth_progress += (int64_t)SQUARE_CLOCK_HZ * 8;
  while (square->eighth_progress >= eighth_length) {
    square->eighth_progress -= eighth_length;
    square->eighth = (square->eighth + 1) & 7;
    square->wave_ticks = square->slid_ticks;
    eighth_length = (int64_t)square->wave_ticks * RG_SOUND_RATE;
  }
  fade_one_sample(&square->loudness);
  return sample;
}

/* --- the wave voice --- */

typedef struct {
  int32_t steps[WAVE_STEPS]; /* the waveform it loops, each step 0 to 15 */
  int32_t switched_on;       /* off, it is silent whatever it is told to play */
  int32_t wave_ticks;        /* ticks all its steps last; 0 when the voice has nothing to play */
  int32_t quarters;          /* its loudness: how many quarters of each step it keeps, 0 to 4 */
  int32_t cut_sum;           /* every step at that loudness, added up */
  int32_t step;              /* which step it is on */
  int64_t step_progress;     /* how far through that step, in ticks times samples a second */
} wave_voice;

static wave_voice wave;
/* Which waveform a tune's note last put in the voice, or -1 once the game's own `wave` or
 * `stop_wave` has been there since (the music feature's wave_put_in). It is kept here because
 * wave_load, which every waveform goes in by, is. */
static int32_t loaded_waveform = -1;

/* A step at the voice's loudness: so many quarters of it, and what does not divide is dropped. */
static int32_t wave_step_cut(int32_t step) { return (step * wave.quarters) / 4; }

/* The voice's loudness is now +quarters+, whatever it is playing. */
static void wave_set_loudness(int32_t quarters) {
  wave.quarters = quarters;
  wave.cut_sum = 0;
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave.cut_sum += wave_step_cut(wave.steps[i]);
}

/* Waveform number +which+ goes into the voice, which switches it on. It plays nothing until its
 * next note: putting a waveform in stops whatever the voice was playing. */
static void wave_load(int32_t which) {
  if (which < 0 || which >= rg_game_waveforms[0]) rg_fault("there is no waveform number %d", (int)which);
  const int32_t *steps = &rg_game_waveforms[1 + (which * WAVE_STEPS)];
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave.steps[i] = steps[i];
  loaded_waveform = which;
  wave.switched_on = 1;
  wave.wave_ticks = 0;
  wave_set_loudness(wave.quarters);
}

/* The voice starts a note from the top of its waveform — if it is switched on. */
static void wave_start(int32_t wave_ticks, int32_t quarters) {
  wave.wave_ticks = wave.switched_on ? wave_ticks : 0;
  wave.step = 0;
  wave.step_progress = 0;
  wave_set_loudness(quarters);
}

static void wave_switch_off(void) {
  wave.switched_on = 0;
  wave.wave_ticks = 0;
}

/* One sample of the voice. Each step is set either side of the middle of the whole waveform at
 * this loudness, so a wave averages nought whatever its shape, as a square voice's does. */
static int32_t wave_sample(void) {
  if (wave.wave_ticks == 0) return 0;

  int32_t sample = STEP_SIZE * ((WAVE_STEPS * wave_step_cut(wave.steps[wave.step])) - wave.cut_sum) / WAVE_STEPS;

  /* A step lasts wave_ticks / 32 ticks: counted, like a square voice's eighth, in ticks times
   * samples a second. */
  int64_t step_length = (int64_t)wave.wave_ticks * RG_SOUND_RATE;
  wave.step_progress += (int64_t)WAVE_CLOCK_HZ * WAVE_STEPS;
  while (wave.step_progress >= step_length) {
    wave.step_progress -= step_length;
    wave.step = (wave.step + 1) % WAVE_STEPS;
  }
  return sample;
}

/* --- the noise voice --- */

typedef struct {
  int32_t step_ticks;    /* ticks one step of the hiss lasts; 0 when the voice has nothing to play */
  int32_t bits;          /* how many bits are in the row */
  uint32_t row;          /* the row of bits */
  int32_t high;          /* which way the last bit to fall off left the voice */
  int32_t heard_high;    /* ...and which way it stood when the speaker was last handed it */
  fading_volume loudness;
  int64_t row_progress;  /* how far through a step, in ticks times hand-overs a second */
  int64_t hand_progress; /* how far to the next hand-over, in hand-overs times samples a second */
} noise_voice;

static noise_voice hiss;

/* A hit: the row starts with every bit set, and steps from there. No ticks, or no volume, is
 * silence.
 *
 * Where a hit starts in its pattern is the emulator's answer. The pattern is one long loop and
 * the same loop wherever it is picked up, so the start is all there is to choose, and every bit
 * set is where the emulator this sound is checked against picks it up. */
static void noise_start(int32_t step_ticks, int32_t bits, int32_t volume, int32_t fade) {
  hiss.step_ticks = step_ticks;
  hiss.bits = bits;
  hiss.row = ((uint32_t)1 << bits) - 1;
  hiss.high = 0;
  hiss.heard_high = 0;
  hiss.loudness = volume_from(volume, fade);
  hiss.row_progress = 0;
  hiss.hand_progress = 0;
}

/* One step of the hiss: the bit at the end falls off and marks which way the voice stands, and
 * when it was set it is stirred back into the two places at the other end. That is the whole of
 * what makes the pattern long: every arrangement of the row comes up before any comes again. */
static void noise_step(void) {
  uint32_t fell = hiss.row & 1u;
  hiss.row >>= 1;
  if (fell) hiss.row ^= (uint32_t)3 << (hiss.bits - 2);
  hiss.high = (int32_t)fell;
}

/* One sample of the voice: high and low either side of nought, half the volume each way.
 *
 * The hiss steps on its own clock, however fast, but the speaker is handed it only so many times
 * a second, and hears whichever way it stood then until the next time. A hiss stepping faster
 * than that is heard as those moments and nothing between them — which is the sound the console
 * makes of it, and so the one made here. */
static int32_t noise_sample(void) {
  if (hiss.step_ticks == 0 || stays_silent(&hiss.loudness)) return 0;

  hiss.hand_progress += OUTPUT_HZ;
  while (hiss.hand_progress >= RG_SOUND_RATE) {
    hiss.hand_progress -= RG_SOUND_RATE;
    int64_t step_length = (int64_t)hiss.step_ticks * OUTPUT_HZ;
    hiss.row_progress += NOISE_CLOCK_HZ;
    while (hiss.row_progress >= step_length) {
      hiss.row_progress -= step_length;
      noise_step();
    }
    hiss.heard_high = hiss.high;
  }
  int32_t sample = STEP_SIZE * hiss.loudness.volume * (hiss.heard_high ? 1 : -1) / 2;
  fade_one_sample(&hiss.loudness);
  return sample;
}

/* --- the sound of a frame --- */

void rg_sound_hear_only(int32_t voice) { heard_only = voice; }

static int32_t heard(int32_t voice, int32_t sample) { return heard_only == 0 || heard_only == voice ? sample : 0; }

/* WHICH SPEAKER EACH CONSOLE VOICE PLAYS FROM (Audio::Pan), by the voice's number: PAN_LEFT,
 * PAN_RIGHT, or nought for both, which every voice is at power-on. A song's note sets its voice's
 * as it starts, and the game's own sound sets its voice back to both. */
static int32_t sides[RG_NOISE_VOICE + 1];

/* A sample of a voice, added to the speakers it plays from. */
static void add_to_sides(int32_t voice, int32_t sample, int32_t *left, int32_t *right) {
  if (sides[voice] != PAN_RIGHT) *left += sample;
  if (sides[voice] != PAN_LEFT) *right += sample;
}

/* Past what a sample holds, it is held at the end: left to wrap, the loudest moment of a game
 * would come out as a jump to the other side of nought. */
static int16_t held_in_range(int32_t sum) {
  if (sum > INT16_MAX) return INT16_MAX;
  if (sum < INT16_MIN) return INT16_MIN;
  return (int16_t)sum;
}

int32_t rg_sound_render_frame(int16_t *left, int16_t *right) {
  sample_carry += (uint64_t)RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME;
  int32_t count = (int32_t)(sample_carry / RG_CONSOLE_TICKS_A_SECOND);
  sample_carry %= RG_CONSOLE_TICKS_A_SECOND;

  /* The mixer's newest slice (the mix feature's), at the mix's own rate, is stretched over the
   * frame: each sample the speaker plays holds the slice's sample at the same point of the frame,
   * as the console's stream holds each sample until the next. It is heard only with every voice.
   * It is asked once here and never once a sample. */
  const int32_t *mixed;
  int32_t mixed_count = heard_only == 0 ? rg_hook_mixed_slice(&mixed) : 0;

  for (int32_t i = 0; i < count; i++) {
    if (++slide_clock == SLIDE_TICK_SAMPLES) {
      slide_clock = 0;
      for (int32_t voice = 1; voice <= RG_SQUARE_VOICES; voice++) slide_one_tick(&squares[voice - 1]);
    }
    int32_t on_left = 0, on_right = 0; /* every voice moves on, heard or not */
    for (int32_t voice = 1; voice <= RG_SQUARE_VOICES; voice++) {
      add_to_sides(voice, heard(voice, square_sample(&squares[voice - 1])), &on_left, &on_right);
    }
    add_to_sides(RG_WAVE_VOICE, heard(RG_WAVE_VOICE, wave_sample()), &on_left, &on_right);
    add_to_sides(RG_NOISE_VOICE, heard(RG_NOISE_VOICE, noise_sample()), &on_left, &on_right);
    if (mixed_count > 0) { /* the recordings play from both */
      int32_t sample = mixed[(int64_t)i * mixed_count / count] * MIX_STEP;
      on_left += sample;
      on_right += sample;
    }
    left[i] = held_in_range(on_left);
    right[i] = held_in_range(on_right);
  }
  return count;
}
/* --- the log --- */

void rg_sound_log(const char *format, ...) {
  char line[64];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof line, format, args);
  va_end(args);
  rg_active_driver->sound_logged(line);
}

/* --- the sounds the game makes itself --- */

void rg_sound_enabled(void) {
  rg_sound_log("enabled");
  for (int32_t voice = 1; voice <= RG_NOISE_VOICE; voice++) sides[voice] = 0; /* every voice from both */
}

/* The game's own sound takes a voice, which then wobbles no song's note, nor steps its shapes
 * (Reference::Player#game_sound_on): said to the features through rg_hook_voice_taken_by_game. */

void rg_sound_beep(int32_t which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault("there is no beep number %d", (int)which);
  const int32_t *beep = &rg_game_beeps[1 + (which * NUMBERS_PER_BEEP)];
  rg_sound_log("beep %d", (int)which);
  rg_hook_voice_taken_by_game(BEEP_VOICE);
  sides[BEEP_VOICE] = 0;
  square_start(BEEP_VOICE, beep[0], beep[1], beep[2], beep[3], 0);
}

void rg_sound_wave(int32_t which) {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault("there is no wave number %d", (int)which);
  const int32_t *said = &rg_game_waves[1 + (which * NUMBERS_PER_WAVE)];
  rg_sound_log("wave %d", (int)which);
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  sides[RG_WAVE_VOICE] = 0;
  wave_load(said[0]);
  wave_start(said[1], said[2]);
  loaded_waveform = -1; /* no player's waveform is there now (see the music feature's wave_put_in) */
}

void rg_sound_stop_wave(void) {
  rg_sound_log("stop_wave");
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE);
  wave_switch_off();
  loaded_waveform = -1;
}

void rg_sound_noise(int32_t which) {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault("there is no hit number %d", (int)which);
  const int32_t *hit = &rg_game_hits[1 + (which * NUMBERS_PER_HIT)];
  rg_sound_log("noise %d", (int)which);
  sides[RG_NOISE_VOICE] = 0;
  noise_start(hit[0], hit[1], hit[2], hit[3]);
}

/* --- the sound features' share of the frame --- */

/* The interpreter's order (Reference#advance_frame): the mixer makes the frame's slice, the tune
 * plays, and then every sounding note's shape moves on. Each feature's hook for the first two is
 * sound_frame, the mix before the music, and the last is sound_frame_ended. */
void rg_sound_frame(void) {
  rg_hook_sound_frame();
  rg_hook_sound_frame_ended();
}

void rg_sound_print_moment(void) { rg_hook_moment_printed(); }

/* --- the state image --- */

static _Noreturn void refuse_damaged_sound(const char *what) {
  rg_fault("This state is damaged: %s. Load a state that this game wrote.", what);
}

/* A loudness as four numbers: now, samples it holds a step, samples left, and whether it swells. */
enum { LOUDNESS_NUMBERS = 4, SQUARE_STATE_NUMBERS = 7 + LOUDNESS_NUMBERS, WAVE_STATE_NUMBERS = WAVE_STEPS + 6,
       NOISE_STATE_NUMBERS = 7 + LOUDNESS_NUMBERS, SOUND_STATE_NUMBERS = 3 + RG_NOISE_VOICE };

static void put_loudness(int64_t *at, const fading_volume *fading) {
  at[0] = fading->volume, at[1] = fading->hold_samples, at[2] = fading->left, at[3] = fading->up;
}

static fading_volume loudness_from(const int64_t *at) {
  if (at[0] < 0 || at[0] >= VOLUMES) refuse_damaged_sound("a voice is louder than a voice can be");
  return (fading_volume){(int32_t)at[0], (int32_t)at[1], (int32_t)at[2], at[3] != 0};
}

/* The console voices' fields (Computer::StateFields "sound" and the rest), then each sound
 * feature's (rg_hook_visit_sound_state). +heard_only+ is a test's, not the game's, and stays. */
void rg_sound_visit_state(void) {
  int64_t general[SOUND_STATE_NUMBERS] = {(int64_t)sample_carry, slide_clock, loaded_waveform};
  for (int32_t voice = 1; voice <= RG_NOISE_VOICE; voice++) general[2 + voice] = sides[voice];
  rg_state_numbers("sound", general, SOUND_STATE_NUMBERS);
  if (general[0] < 0 || general[0] >= RG_CONSOLE_TICKS_A_SECOND || general[1] < 0 || general[1] >= SLIDE_TICK_SAMPLES ||
      general[2] < -1 || general[2] >= rg_game_waveforms[0])
    refuse_damaged_sound("the sound is somewhere it cannot be");
  sample_carry = (uint64_t)general[0], slide_clock = (int32_t)general[1], loaded_waveform = (int32_t)general[2];
  for (int32_t voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    if (general[2 + voice] != 0 && general[2 + voice] != PAN_LEFT && general[2 + voice] != PAN_RIGHT)
      refuse_damaged_sound("a voice plays from a speaker there is not");
    sides[voice] = (int32_t)general[2 + voice];
  }

  int64_t square_numbers[RG_SQUARE_VOICES * SQUARE_STATE_NUMBERS];
  for (int32_t i = 0; i < RG_SQUARE_VOICES; i++) {
    const square_voice *s = &squares[i];
    int64_t *at = square_numbers + i * SQUARE_STATE_NUMBERS;
    at[0] = s->wave_ticks, at[1] = s->eighths_high, at[2] = s->eighth, at[3] = s->eighth_progress, at[4] = s->slide;
    at[5] = s->slide_left, at[6] = s->slid_ticks;
    put_loudness(at + 7, &s->loudness);
  }
  rg_state_numbers("sound.squares", square_numbers, RG_SQUARE_VOICES * SQUARE_STATE_NUMBERS);
  for (int32_t i = 0; i < RG_SQUARE_VOICES; i++) {
    const int64_t *at = square_numbers + i * SQUARE_STATE_NUMBERS;
    if (at[2] < 0 || at[2] > 7 || at[0] < 0 || at[6] < 0) refuse_damaged_sound("a square voice is part way through a wave it cannot be");
    squares[i] = (square_voice){(int32_t)at[0], (int32_t)at[1], loudness_from(at + 7), (int32_t)at[2], at[3], (int32_t)at[4],
                                (int32_t)at[5], (int32_t)at[6]};
  }

  int64_t wave_numbers[WAVE_STATE_NUMBERS];
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave_numbers[i] = wave.steps[i];
  int64_t *rest = wave_numbers + WAVE_STEPS;
  rest[0] = wave.switched_on, rest[1] = wave.wave_ticks, rest[2] = wave.quarters, rest[3] = wave.cut_sum, rest[4] = wave.step;
  rest[5] = wave.step_progress;
  rg_state_numbers("sound.wave", wave_numbers, WAVE_STATE_NUMBERS);
  if (rest[4] < 0 || rest[4] >= WAVE_STEPS || rest[1] < 0) refuse_damaged_sound("the wave voice is on a step it does not have");
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave.steps[i] = (int32_t)wave_numbers[i];
  wave.switched_on = rest[0] != 0, wave.wave_ticks = (int32_t)rest[1], wave.quarters = (int32_t)rest[2];
  wave.cut_sum = (int32_t)rest[3], wave.step = (int32_t)rest[4], wave.step_progress = rest[5];

  int64_t noise_numbers[NOISE_STATE_NUMBERS] = {hiss.step_ticks, hiss.bits,         hiss.row,         hiss.high,
                                                hiss.heard_high, hiss.row_progress, hiss.hand_progress};
  put_loudness(noise_numbers + 7, &hiss.loudness);
  rg_state_numbers("sound.noise", noise_numbers, NOISE_STATE_NUMBERS);
  if (noise_numbers[0] < 0 || (noise_numbers[0] != 0 && (noise_numbers[1] < 2 || noise_numbers[1] > 31)) || noise_numbers[2] < 0 ||
      noise_numbers[2] > UINT32_MAX)
    refuse_damaged_sound("the noise voice holds a row of bits it cannot");
  hiss = (noise_voice){(int32_t)noise_numbers[0], (int32_t)noise_numbers[1], (uint32_t)noise_numbers[2], (int32_t)noise_numbers[3],
                       (int32_t)noise_numbers[4], loudness_from(noise_numbers + 7), noise_numbers[5], noise_numbers[6]};

  rg_hook_visit_sound_state();
}

/* The game's sound features and the hooks they take, written by the build beside game.c
 * (RuntimeFeatures#c_text); then what a hook none of them takes does. A file read on its own, by
 * the editor's checker, has no game and so no features. */
#if __has_include("rg_sound_features.h")
#include "rg_sound_features.h"
#endif
#include "rg_sound_hook_defaults.h"
