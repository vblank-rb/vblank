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
/* A game that mixes at sixteen bits: each sample's low byte, beside its high byte above (rg_mix.c). */
extern const uint8_t rg_game_recording_low_bytes[];

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

/*
 * A RECORDING'S SETTINGS IN THE FILE (IR::StartFile::RecordingSettings): the rate it was recorded
 * at, the sample a held note reads back to, and its envelope. The game works a play and a note
 * out from them as it is built, so it holds a stand-in for each number worked out, and these
 * write the number again from the file. Each writes entries of +into+: the game's own array for
 * the numbers of its plays, or the table of recordings or of note rows (rg_music.h).
 * A number in the file is four of +rules+: where it is, how many bytes, 1 for the high byte
 * first, and 1 where it can be below zero. The file is the player's, and the game plays on
 * whatever it holds.
 *
 * rg_mix_fill_steps: the step a voice reads the recording at (IR::Mixing.step), from its
 * rate. +rules+: the rate's four numbers, the rate the mix runs at as two halves of a number with
 * a fraction (the high half first), how many steps, and for each the entry of +into+ and, as two
 * halves, the note it sounds against the note the recording was made at. A rate below 1 is 1.
 *
 * rg_mix_fill_holds: how far back a held note reads at the recording's end, from the
 * sample it holds from. +rules+: that sample's four numbers, the recording's length, 1 where
 * holding from none reads it all again (a play that loops) or 0 where it reads nothing again (a
 * note), how many entries, and each entry of +into+. A sample outside the recording is its first
 * or its last, and one with every bit set is none (IR::StartFile.no_hold?).
 *
 * rg_mix_fill_shapes: an envelope, from bytes of the file. +rules+: where they are, how they are
 * kept (0, four bytes: attack, decay, sustain, release; 1, the three the Super Nintendo's sound
 * chip keeps, adsr1, adsr2 and gain, played as the nearest ordinary envelope,
 * Audio::SNESEnvelope#closest_envelope), the most a level is, the shift a level scales by, the
 * frames a second a level moves at, how many entries, and each entry of +into+, where five
 * numbers start: 1 and the four for a shape, all 0 for the one that is no shape at all. */
void rg_mix_fill_steps(int32_t *into, const int32_t *rules);
void rg_mix_fill_holds(int32_t *into, const int32_t *rules);
void rg_mix_fill_shapes(int32_t *into, const int32_t *rules);

/* A RECORDING'S LENGTH IN THE FILE (IR::StartFile::RecordingSettings#length): how many of its
 * samples it plays, 1 at least and the room the game holds for them at most.
 *
 * rg_mix_fill_length: that length. +rules+: its four numbers, the room, how many entries, and each
 * entry of +into+ (a recording's length in the table of recordings).
 *
 * rg_mix_fill_backs: how far back a play or a note reads at the recording's end, which is the
 * length less the sample it holds from. +rules+: the length's four numbers and the room; 1 where
 * the sample it holds from is in the file, those four numbers (or four 0s), and the sample the game
 * gave (-1 for none; a sample past the end is the last; one in the file with every bit set is
 * none); 1 where holding from none reads it all again
 * (a play that loops) or 0 where it reads nothing again (a note); how many entries; each entry. */
void rg_mix_fill_length(int32_t *into, const int32_t *rules);
void rg_mix_fill_backs(int32_t *into, const int32_t *rules);

/* A RECORDING IN THE SUPER NINTENDO SOUND CHIP'S FORMAT IN THE FILE (IR::StartFile::BRR), decoded
 * as the game starts as Audio::SNESRecording#decoded decodes it, held as IR::StartFile::BRR says.
 *
 * rg_mix_fill_brr: the samples, into +samples+, and how many there are and the sample a held note
 * reads back to (-1 for none) into two entries of +decoded+. +rules+: where the samples start in
 * +samples+, the room they have, where the recording is in the file and how many bytes, the entry
 * of +decoded+, how many times at most it is decoded round its loop, then 1 where the loop point
 * is in the file or 0 where the game wrote it, the loop point the game wrote, and the loop point's
 * four numbers (or four 0s).
 *
 * rg_mix_fill_decoded_length: the length, into each of +into+'s entries. +rules+: the entry of
 * +decoded+, how many entries, and each entry.
 *
 * rg_mix_fill_decoded_backs: how far back a play or a note reads at the recording's end. +rules+:
 * the entry of +decoded+, 1 where holding from none reads it all again (a play that loops) or 0
 * where it reads nothing again (a note), how many entries, and each entry. */
void rg_mix_fill_brr(int8_t *samples, int32_t *decoded, const int32_t *rules);
void rg_mix_fill_decoded_length(int32_t *into, const int32_t *decoded, const int32_t *rules);
void rg_mix_fill_decoded_backs(int32_t *into, const int32_t *decoded, const int32_t *rules);

#endif
