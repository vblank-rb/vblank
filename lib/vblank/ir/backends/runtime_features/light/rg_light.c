/*
 * A LIGHT (Framebuffer#shade_outside, Reference#work_out_shade): a `spotlight` or an `iris_out`,
 * which darkens the picture everywhere outside one span of each row, as it is shown. A runtime
 * feature (backends/runtime_features.rb): this file is included at the end of rg_screen.c, for a
 * game that has a light, so it reads the screen's own state and painters as if it were written
 * there. A game with no light builds without it.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table and the rows
 * (rg_light_dim_filter) that the darkened part of the picture is read through.
 */
#include "rg_light.h"

/* Each row's lit span as the gap between frames last worked it out, and how many sixteenths the
 * rest of the row is darkened by: nought until then, which darkens nothing. */
static int32_t shade_spans[RG_SCREEN_HEIGHT][2];
static int32_t shade_steps;
static int32_t shade_row;

int32_t rg_shade_line(void) { return shade_row; }

/* Where the row's span starts, and then where it ends: two calls, so the game works the left
 * edge out before the right one, as the interpreter does — the arguments of one call could be
 * worked out in either order. */
void rg_shade_left(int32_t left) { shade_spans[shade_row][0] = left; }
void rg_shade_right(int32_t right) { shade_spans[shade_row][1] = right; }

/* FadeSteps.sixteenths: the amount out of 100, in the display's sixteenths. */
void rg_shade_darkness(int32_t amount) { shade_steps = whole_sixteenths(amount); }

/* THE FILTER THE DARKENED PART OF THE PICTURE IS READ THROUGH: the table darkens a colour by the
 * light's steps, and each screen row says which of its pixels are dark, a pixel being changed when
 * +inverted+ XOR from <= x < to (see shown_filter). Worked out at the end of
 * rg_screen_work_out_shade, which is the only place the spans change. */
static shown_filter dim_filter;
static uint16_t dim_table[65536];
static int32_t dim_rows[RG_SCREEN_HEIGHT][3];
static int32_t dim_table_steps = -1; /* the steps the table was made for, or -1 for none yet */

/* Framebuffer#lit?, row by row: is (x, y) inside its row's span? A span that comes round the edge
 * (left past right) is lit outside [right, left), so the dark pixels are the ones within it; a
 * span that does not is lit within [left, right), so the dark ones are outside it. */
static void fill_dim_rows(void) {
  for (int32_t y = 0; y < RG_SCREEN_HEIGHT; y++) {
    int32_t left = shade_spans[y][0], right = shade_spans[y][1];
    dim_rows[y][0] = left <= right ? left : right;
    dim_rows[y][1] = left <= right ? right : left;
    dim_rows[y][2] = left <= right;
  }
}

/* Reference#work_out_shade: every row's span from the game's own expressions, top to bottom,
 * then the amount. */
void rg_screen_work_out_shade(void) {
  for (shade_row = 0; shade_row < RG_SCREEN_HEIGHT; shade_row++) rg_game_shade_span();
  rg_game_shade_amount();
  fill_dim_rows();
}

/* Framebuffer#light_off=: whether the scene that just ran has the light switched off, set as
 * the frame ends, before it is shown (Reference#advance_frame). */
static int32_t shade_off;
void rg_shade_switch(int32_t on) { shade_off = on == 0; }

/* Whether no light is darkening any of the picture. */
static int32_t every_pixel_lit(void) { return shade_steps == 0 || shade_off; }

/* rg_hook_dim_filter (Framebuffer#shade_outside, #lit?): nothing while no light darkens any of the
 * picture, else the filter above, its table made again when the steps are not the ones it was
 * made for. */
static const shown_filter *rg_light_dim_filter(void) {
  if (every_pixel_lit()) return NULL;
  if (dim_table_steps != shade_steps) {
    for (uint32_t color = 0; color < 65536; color++) dim_table[color] = darkened_by_display((uint16_t)color, shade_steps);
    dim_table_steps = shade_steps;
  }
  dim_filter.table = dim_table;
  dim_filter.everywhere = 0;
  dim_filter.rows = dim_rows;
  dim_filter.remix = 0;
  return &dim_filter;
}
