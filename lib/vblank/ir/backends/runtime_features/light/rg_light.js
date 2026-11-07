/*
 * A LIGHT (Framebuffer#shade_outside, Reference#work_out_shade): a `spotlight` or an `iris_out`,
 * which darkens the picture everywhere outside one span of each row, as it is shown. A runtime
 * feature (backends/runtime_features.rb), joined into the runtime's script after rg_screen.js for
 * a game that has a light, so it reads the screen's own state and painters as if it were written
 * there. rg_light.c says how, rule for rule; this is that file written again, function for
 * function.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table and the rows
 * (rg_light_dim_filter) that the darkened part of the picture is read through. As in rg_fades.js,
 * the table is filled as colours are looked up and started again when the light's darkness changes.
 */

/* Each row's lit span as the gap between frames last worked it out, and how many sixteenths the
 * rest of the row is darkened by: nought until then, which darkens nothing. */
const shade_spans = new Int32Array(RG_SCREEN_HEIGHT * 2);
let shade_steps = 0;
let shade_row = 0;

function rg_shade_line() { return shade_row; }

/* Where the row's span starts, and then where it ends: two calls, so the game works the left
 * edge out before the right one, as the interpreter does. */
function rg_shade_left(left) { shade_spans[shade_row * 2] = left; }
function rg_shade_right(right) { shade_spans[shade_row * 2 + 1] = right; }

/* FadeSteps.sixteenths: the amount out of 100, in the display's sixteenths. */
function rg_shade_darkness(amount) { shade_steps = whole_sixteenths(amount); }

/* THE FILTER THE DARKENED PART OF THE PICTURE IS READ THROUGH (see shown_filter in rg_screen.js):
 * the table darkens a colour by the light's steps, and each screen row says which of its pixels are
 * dark, a pixel being changed when inverted XOR from <= x < to. The rows are worked out at the end
 * of rg_screen_work_out_shade, which is the only place the spans change. */
const dim_filter = {
  table: new Int32Array(65536).fill(-1),
  everywhere: false,
  rows: new Int32Array(RG_SCREEN_HEIGHT * 3),
  remix: false,
  fill(color) { return (this.table[color] = darkened_by_display(color, shade_steps)); },
};
let dim_table_steps = -1; /* the steps the table was started for, or -1 for none yet */

/* Framebuffer#lit?, row by row: is (x, y) inside its row's span? A span that comes round the edge
 * (left past right) is lit outside [right, left), so the dark pixels are the ones within it; a
 * span that does not is lit within [left, right), so the dark ones are outside it. */
function fill_dim_rows() {
  for (let y = 0; y < RG_SCREEN_HEIGHT; y++) {
    const left = shade_spans[y * 2], right = shade_spans[y * 2 + 1];
    dim_filter.rows[y * 3] = left <= right ? left : right;
    dim_filter.rows[y * 3 + 1] = left <= right ? right : left;
    dim_filter.rows[y * 3 + 2] = left <= right ? 1 : 0;
  }
}

/* Reference#work_out_shade: every row's span from the game's own expressions, top to bottom,
 * then the amount. */
function rg_screen_work_out_shade() {
  for (shade_row = 0; shade_row < RG_SCREEN_HEIGHT; shade_row++) rg_game_shade_span();
  rg_game_shade_amount();
  fill_dim_rows();
}

/* Framebuffer#light_off=: whether the scene that just ran has the light switched off, set as
 * the frame ends, before it is shown (Reference#advance_frame). */
let shade_off = false;
function rg_shade_switch(on) { shade_off = on === 0; }

/* Whether no light is darkening any of the picture. */
function every_pixel_lit() { return shade_steps === 0 || shade_off; }

/* rg_hook_dim_filter (Framebuffer#shade_outside, #lit?): nothing while no light darkens any of the
 * picture, else the filter above, its table started again when the steps are not the ones it was
 * started for. */
function rg_light_dim_filter() {
  if (every_pixel_lit()) return null;
  if (dim_table_steps !== shade_steps) {
    dim_filter.table.fill(-1);
    dim_table_steps = shade_steps;
  }
  return dim_filter;
}
