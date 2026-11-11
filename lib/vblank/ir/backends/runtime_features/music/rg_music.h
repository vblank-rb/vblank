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
 * starts (rg_start_file_fill_notes), and says so before this header (RG_MUSIC_WRITABLE). */
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

#endif
