/*
 * THE MIXER: several recordings sounding at once, added together a frame at a time into one
 * stream of sound, the way the console's own software mixer does it (Backends::Reference::Mixer
 * does the same arithmetic in Ruby, and is held to the console byte for byte; this is held to
 * it).
 *
 * The console has no voice that plays a recording by itself, only one that plays a stream it is
 * handed. So the game's CPU adds every sounding recording together into that stream, a frame's
 * slice of it at a time, and that is what this does. Each recording plays on a VOICE of the
 * mixer — there are a fixed number — which it gives back when it ends.
 */
#ifndef RG_MIX_H
#define RG_MIX_H

#include <stdint.h>

/* What the lowering writes (see rg_mix.c for the layouts): how the mix runs, and every recording
 * the game declares, with its bytes. */
extern const int32_t rg_game_mix[];
/* A game with a recording that reads its envelope from the start file writes its shape into this
 * table as it starts, and says so before this header (RG_RECORDINGS_WRITABLE). */
#ifdef RG_RECORDINGS_WRITABLE
extern int32_t rg_game_recordings[];
#else
extern const int32_t rg_game_recordings[];
#endif
/* A game whose recordings read their samples from the start file writes this array as it starts,
 * and says so before this header (RG_RECORDING_SAMPLES_WRITABLE). */
#ifdef RG_RECORDING_SAMPLES_WRITABLE
extern int8_t rg_game_recording_samples[];
#else
extern const int8_t rg_game_recording_samples[];
#endif

/* The game's own `play` of recording number +recording+: read +step+ 65536ths of a sample for
 * each sample of the mix (its pitch), at +loudness+ out of 512, going +back+ that many samples at
 * its end (0 to stop there), and +loops+ if it was asked to, which decides who gives way when a
 * song's note wants its voice. Every number was worked out when the game was built. With every
 * voice busy it takes the quietest of the song's notes falling away, or is dropped. */
void rg_mix_play(int32_t recording, int32_t step, int32_t loudness, int32_t back, int32_t loops);

/* A NOTE OF THE SONG'S on part +lane+ (counted among its parts that play recordings), from a song
 * of +rank+ (IR::Tunes.song_rank) — or of SOUND EFFECT number +effect+, of the effect's rank, for an
 * +effect+ other than -1. +sound+ is the recording, the step, how far back it reads, and
 * its shape (whether it has one, then four numbers), and +loudness+ is out of 512. Which voice it
 * gets is the interpreter's rule (Reference::Mixer#start_music_note): the part's own, unless its
 * note there has a shape and is left to fall away; then a free one; then the quietest note
 * falling away; then the lowest-ranked sound below this one, the game's own first and of those
 * the one playing longest, a one-shot before a loop. Nought when it got none and is not played. */
int32_t rg_mix_start_music_note(int32_t effect, int32_t lane, int32_t rank, const int32_t *sound, int32_t loudness);
int32_t rg_mix_glide_music_note(int32_t effect, int32_t lane, const int32_t *sound);

/* A part rests: its note ends, falling away if it has a shape. Nought when it had none sounding.
 * The part is the song's for an +effect+ of -1, else that sound effect's (as above). */
int32_t rg_mix_release_music(int32_t effect, int32_t lane);
/* The song stops or changes: every note it holds ends the same way. */
void rg_mix_release_all_music(void);
/* The music volume moved: part +lane+'s sounding note plays at +loudness+ from now on. Nought
 * when it has none sounding. */
int32_t rg_mix_rescale_music(int32_t lane, int32_t loudness);

/* The game's `stop`: every voice of the game's sounding recording number +recording+ goes, or
 * every voice of the game's for -1. */
void rg_mix_stop(int32_t recording);

#endif
