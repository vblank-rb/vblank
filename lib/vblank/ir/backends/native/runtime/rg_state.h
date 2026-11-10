/*
 * THE STATE IMAGE: everything a game and its runtime keep between two frames, written as text by
 * name, and read back into the same build so the game plays on from there.
 *
 * The image is one line a field: its name, a tab, how many numbers it holds, and the numbers, all
 * as decimal whole numbers. A run of RG_STATE_SHORTEST_RUN or more of one number is written as one word,
 * "times*number" ("38400*0" is a blank page), since a picture is most of the image and mostly runs.
 * A field is the game's own (a variable, a list, a routine's place, a patch of picture kept under a
 * sprite, all written by the build in rg_game_visit_state) or the runtime's (the buttons, the
 * timers, the clock, the motor, the save memory, the screen, each part visiting its own). The
 * runtime's fields are the ones Computer::StateFields lists, in its order; the JavaScript and Ruby
 * runtimes visit the same, so an image written by one reads on the others.
 *
 * EACH FIELD IS NAMED ONCE AND USED BOTH WAYS. A part hands a field to a visit call; writing the
 * image prints it, reading the image stores what the image holds under that name into it. So
 * writing and reading cannot disagree about what a field is or where it lives.
 *
 * Only at a frame boundary: every routine that can wait is stopped at its wait then, so the chain
 * of routines the game is inside is numbers in its globals, and the image holds it whole.
 */
#ifndef RG_STATE_H
#define RG_STATE_H

#include <stdint.h>
#include <stdio.h>
#include "rg_list.h"

enum { RG_STATE_SHORTEST_RUN = 4 }; /* the shortest run of one number written as "times*number" */

/* Writes the whole state to +out+. */
void rg_state_write(FILE *out);

/* Reads an image from +text+ into the game and its runtime. One that names a field this build does
 * not keep, lacks one it does, or holds a different count stops the game saying which. */
void rg_state_read(const char *text);

/* The words for why the image in +text+ is not this build's (not a state, another version, another
 * build), or NULL when its first two lines are this build's. Changes nothing, so a window asks before
 * it reads, and tells the player instead of stopping the game. */
const char *rg_state_header_problem(const char *text);

/* Whether an image is being read just now, rather than written. */
int rg_state_reading(void);

/* --- what a part calls for each field it keeps --- */

/* A field of one number the build wrote as a global: written, or given back from the image. */
int32_t rg_state_number(const char *name, int32_t value);

/* A list: its slots, where the oldest is, and how many it holds, as the ring stands. */
void rg_state_list(const char *name, rg_list *list);

/* A field of +count+ numbers kept at +values+. */
void rg_state_numbers(const char *name, int64_t *values, int32_t count);

/* The game's own fields, written by the build (Computer::Lowering#visit_state). */
void rg_game_visit_state(void);

/* Each runtime part's own fields, in Computer::StateFields's order. */
void rg_runtime_visit_state(void);
void rg_save_visit_state(void);
void rg_screen_visit_state(void);
void rg_sound_visit_state(void);

/* A patch of picture kept under a sprite (rg_patch_save), +width+ by +height+: whether it was
 * saved, then its cells. The build visits each patch the game declares. */
void rg_patch_visit_state(const char *name, int32_t buffer, int32_t width, int32_t height);

#endif
