/*
 * THE GAME'S SOUND: the console's four voices, the game's own sounds, and the log of what was
 * played.
 *
 * A game that plays a tune or a sound effect also has the music player, and one that plays a
 * recording has the mixer: each a runtime feature of its own (rg_music.h, rg_mix.h) joined into
 * rg_sound.c, so a game without them is built without them. What they do is said as the lines of
 * the log (the interpreter's `audio`), handed to the driver as they happen.
 *
 * The voices are the console's, made here because a desktop has no sound chip to ask. Two play
 * a square wave, high for part of its length and low for the rest. One loops a waveform of 32
 * steps, which is rounder than a square wave and reaches an octave lower. One makes a hiss, for
 * drums and explosions. Each plays at the pitch and loudness the player or the game last gave
 * it. A driver asks for a frame's worth of that sound at every frame and does what it likes with
 * it — a window plays it, a test writes it down.
 */
#ifndef RG_SOUND_H
#define RG_SOUND_H

#include <stdint.h>

/* The sound comes out as whole numbers from -32768 to 32767, one speaker's worth, this many a
 * second. A frame of the console is a little over eight hundred of them. */
#define RG_SOUND_RATE 48000
#define RG_SOUND_FRAME_MOST 1024

/* The voices by the console's own count of them, which is what the log names a voice by and what
 * a test asks to hear one by. */
#define RG_SQUARE_VOICES 2
#define RG_WAVE_VOICE 3
#define RG_NOISE_VOICE 4

/* The rules the voices keep and every sound the game makes itself, as numbers (the lowering writes
 * them; see rg_sound.c for the layouts). */
extern const int32_t rg_game_sound_rules[];
/* A game with a part that reads its wave from the start file writes it into this table as it
 * starts (the music feature does, through its own header), and defines RG_WAVEFORMS_WRITABLE
 * before this header. */
#ifdef RG_WAVEFORMS_WRITABLE
extern int32_t rg_game_waveforms[];
#else
extern const int32_t rg_game_waveforms[];
#endif
/* On a console whose voices read sound memory, the wave numbered +which+ (just written from the
 * start file into +waveforms+) written into its loop of +memory+, the game's sound memory
 * (rg_spu.c). */
void rg_spu_fill_wave(int32_t *memory, const int32_t *waveforms, int32_t which);
/* On such a console, a recording whose hold is read from the start file laid out round its way back
 * and encoded into the loop of +memory+ kept for it (PS1::SoundMemory.holds_read_from_file), as the
 * build lays out and encodes a hold written in the game. +recordings+ is rg_game_spu_recordings, its
 * way back just filled (rg_mix_fill_holds); +recording_samples+ the mixer's samples. +rules+: the
 * recording's number, where its samples start, how many there are, and where the loop starts, in
 * 8-byte steps. */
void rg_spu_fill_held_recording(int32_t *memory, const int32_t *recordings, const int8_t *recording_samples, const int32_t *rules);
extern const int32_t rg_game_beeps[];
extern const int32_t rg_game_waves[];
extern const int32_t rg_game_hits[];

/* `enable_sound`, and beep number +which+ of the game's beeps (numbered by the lowering and by
 * the test reading the log the same way, so the number is all that needs saying). */
void rg_sound_enabled(void);
void rg_sound_beep(int32_t which);

/* `wave`: the wave voice plays number +which+ of the things the game tells it to, until it is
 * told something else. And `stop_wave`, which switches the voice off. */
void rg_sound_wave(int32_t which);
void rg_sound_stop_wave(void);

/* `noise`: hit number +which+ of the game's hits, on the noise voice. */
void rg_sound_noise(int32_t which);

/* The sound features' share of one frame, at the start of each frame (rg_frame_begins): the
 * mixer's slice, then the tune, then every sounding note's shape, for the features a game has. */
void rg_sound_frame(void);

/* What the sound features print of their own state for a windowless run (rg_headless.c). */
void rg_sound_print_moment(void);

/* The sound of the frame that has just been played, the left speaker's written to +left+ and the
 * right's to +right+ (room for RG_SOUND_FRAME_MOST each); gives back how many each. Asked once a
 * frame, at the frame's end and before rg_frame_begins starts the next: a beep the game made
 * during the frame is then in that frame's sound, where the console plays it, and not a frame
 * behind. */
int32_t rg_sound_render_frame(int16_t *left, int16_t *right);

/* One line of the sound log, said the way printf says it, handed to the driver as it happens. */
void rg_sound_log(const char *format, ...);

/* Only voice +voice+ is heard from now on — 1 or 2 for a square voice, RG_WAVE_VOICE,
 * RG_NOISE_VOICE — or every voice for 0: how a test listens to one voice at a time. */
void rg_sound_hear_only(int32_t voice);

#endif
