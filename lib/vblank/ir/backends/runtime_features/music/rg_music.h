/*
 * What a game that plays a tune or a sound effect calls (rg_music.c): the music player and the
 * sound effects, which are songs the same player walks. The player follows the interpreter's own
 * (Backends::Reference::Player) step for step, and says what it did — a song started, a note
 * sounded on a voice, the music turned down — as the lines of the sound log (rg_sound.h).
 */
#ifndef RG_MUSIC_H
#define RG_MUSIC_H

#include <stdint.h>

/* Every song the game has and every sound effect it makes, as numbers (the lowering writes them;
 * see rg_music.c for the layouts). */
/* A game with a part that reads its notes from the start file writes them into this table as it
 * starts (rg_music_fill_notes, below), and says so before this header (RG_MUSIC_WRITABLE). */
#ifdef RG_MUSIC_WRITABLE
extern int32_t rg_game_music[];
#else
extern const int32_t rg_game_music[];
#endif
/* A game with a recording that reads its settings from the start file writes the note rows worked
 * out from them as it starts, and says so before this header (RG_NOTE_SOUNDS_WRITABLE). */
#ifdef RG_NOTE_SOUNDS_WRITABLE
extern int32_t rg_game_note_sounds[];
#else
extern const int32_t rg_game_note_sounds[];
#endif
extern const int32_t rg_game_effects[];

/* Song number +song+ is the tune playing now, taken up at the next frame; naming the tune already
 * playing changes nothing. */
void rg_music_request(int32_t song);
/* ...or the song number +which+ of a list (`songs`) names, from the +count+ song numbers the list
 * holds. A number naming no song in the list leaves the music as it is. */
void rg_music_request_one_of(const int32_t *songs, int32_t count, int32_t which);
/* `this_frame: true`: the tune named starts here and its first frame is played, so the next frame
 * plays its second. After rg_music_request; the list's own does both, for a number naming a song,
 * and nothing otherwise. */
void rg_music_start_here(void);
void rg_music_start_here_one_of(const int32_t *songs, int32_t count, int32_t which);
/* Start the sound effect number +which+ of a list (`sound_effects`) names, from the +count+ effect
 * numbers the list holds, at the next frame and from its first note. A number naming no effect in
 * the list plays nothing. */
void rg_effect_request_one_of(const int32_t *effects, int32_t count, int32_t which);
/* ...or asked for `this_frame: true`: started here, its first frame played, so the next frame
 * plays its second — and any effect of a group waiting to be cut off cut off here too. */
void rg_effect_start_here_one_of(const int32_t *effects, int32_t count, int32_t which);
/* No tune, and counted: a stop and a play in one frame still start the tune again. */
void rg_music_stop(void);
void rg_music_hold(int32_t held);
/* The variable the game keeps its music volume in (0 to 16), for a game that names one at all. */
void rg_music_follow_level(const int32_t *level);

/*
 * A PART'S NOTES IN THE FILE (IR::StartFile::Notes): records of twelve bytes that a port's
 * unpacking writes (Original::PackNote), low byte first: the tick a note starts on and how many
 * ticks it lasts (two bytes each, 0 for until the next), its key (0 to 127, anything else a rest),
 * which of the part's instruments it plays and its volume (0 to 15), each the part's own where
 * it names none the part has, the speaker it plays from on a part that does not play a recording
 * (0 both, 1 left, 2 right, anything else the part's own), its loudness in 512ths on a part that
 * plays a recording (two bytes, 65535 for none, past 512 all of it), the noise clock it plays in
 * place of its key on a part that takes one (a byte below the number of clocks the part takes),
 * and a byte of nothing. A record starting on tick 65535 ends the part. The game holds room for the notes in rg_game_music, each on frame -1, which
 * the player never reaches, and this writes the notes the records make over the first of them.
 *
 * rg_music_fill_notes makes them by the one rule every backend keeps (Audio::Score::Events
 * and IR::Tunes.loop_passes say why each step is so): the records in the order of their ticks,
 * those on one tick in the file's order; each an event on its tick's frame, and a rest where its
 * length runs out unless the next record has begun by then; the later of two events on one
 * frame; none on a frame at or past the song's end; and, for a song that comes round, the part
 * put right at its loop frame, in the notes it plays the first time through and those it plays
 * every time after. +tick_frames+ is the frame each tick falls on, for every tick before the
 * song's end. +rules+: where the part's first note is in +music+, how many ticks +tick_frames+
 * holds, the room for notes the first time through and for every time after, where the records
 * are in the file and how many at most, where the song's length in frames is in +music+ (the
 * frame it comes round to is the number after), 1 if it comes round, a rest's fourth number, the
 * fifth and sixth numbers of a note that sounds, how many instruments the part names, 1 if it
 * plays a recording, the fifth number for a note that names each of the three speakers, and how
 * many noise clocks the part takes, and how many bytes a record is (12, or 32 for a record with its
 * voice's settings, Original::PackNote's voiced record). Then a
 * note's third number for each volume from 0 to 15 and for the part's own; for each instrument
 * the first that names the same recording; a note's second number for each of the 128 keys;
 * its fourth for each key, on the part's own instrument and then on each it names; and its second
 * and then its fourth for each noise clock the part takes. For voiced records: the bits of the
 * record's names the part takes, how many pitch numbers it takes, and a note's second and then
 * its fourth for each; a record's fade, duty, vibrato and slide go into a note's fifth and sixth
 * numbers in the bits the game writes them in. Every number
 * of a note is one the game worked out as it was built: nothing here tunes a key or times a tick. */
void rg_music_fill_notes(int32_t *music, const int32_t *rules, const int32_t *tick_frames);

/* A SONG'S LENGTH IN THE FILE (IR::StartFile::SongLength): the tick it ends or comes round on,
 * and the tick it comes round to, each a number a port's unpacking wrote. The game holds the most
 * frames the song can last as its length, and this writes the frames those ticks fall on over the
 * song's length and loop frame in +music+, before any of its parts' notes are made. +rules+: where
 * the song's length is in +music+, how many ticks +tick_frames+ holds, the most frames the song can
 * last; then 1 where the length is in the file and the four numbers saying where (its place, its
 * bytes, 1 for the high byte first, 1 where it can be below zero), and the same five for the loop
 * tick. A tick below zero is 0; a length below a frame is a frame and one past the most is the
 * most; a loop frame on or past the end is the song's start (IR::StartFile::SongLength#frames_in). */
void rg_music_fill_song_length(int32_t *music, const int32_t *rules, const int32_t *tick_frames);

#endif
