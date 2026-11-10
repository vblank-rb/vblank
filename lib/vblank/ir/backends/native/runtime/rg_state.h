/*
 * THE STATE IMAGE: everything a game and its runtime keep between two frames, written as text by
 * name, and read back into the same build so the game plays on from there.
 *
 * The image is one line a field: its name, a tab, how many numbers it holds, and the numbers, all
 * as decimal whole numbers. A field is the game's own (a variable, a list, a routine's place, all
 * written by the build in rg_game_visit_state) or the runtime's (the buttons, the timers, the
 * clock, the motor, the save memory, each part visiting its own). The runtime's fields are the
 * ones Computer::StateFields lists, in its order; the JavaScript and Ruby runtimes visit the same,
 * so an image written by one reads on the others.
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

/* Writes the whole state to +out+. */
void rg_state_write(FILE *out);

/* Reads an image from +text+ into the game and its runtime. One that names a field this build does
 * not keep, lacks one it does, or holds a different count stops the game saying which. */
void rg_state_read(const char *text);

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

#endif
