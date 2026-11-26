/*
 * A light (Framebuffer#shade_outside, Reference#work_out_shade): a `spotlight` or an `iris_out`, which darkens the picture
 * everywhere outside one span of each row, as it is shown. A port of the JavaScript runtime's rg_light.js, function for
 * function (rg_light.c says how, rule for rule). A runtime feature (backends/runtime_features.rb), joined into the runtime
 * after rg_screen.hx for a game that has a light, so it reads the screen's own state and painters as if it were written
 * there.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table and the rows (rg_light_dim_filter)
 * that the darkened part of the picture is read through. As in rg_fades.hx, the table is filled as colours are looked up
 * (it holds the colour plus one) and started again when the light's darkness changes.
 */

/* Each row's lit span as the gap between frames last worked it out, and how many sixteenths the rest of the row is
 * darkened by: nought until then, which darkens nothing. */
static var shade_spans:Vector<Int> = new Vector<Int>(RG_SCREEN_HEIGHT * 2);
static var shade_steps:Int = 0;
static var shade_row:Int = 0;

static function rg_shade_line():Int { return shade_row; }

/* Where the row's span starts, and then where it ends: two calls, so the game works the left edge out before the right
 * one, as the interpreter does. */
static function rg_shade_left(left:Int):Void { shade_spans[shade_row * 2] = left; }
static function rg_shade_right(right:Int):Void { shade_spans[shade_row * 2 + 1] = right; }

/* FadeSteps.sixteenths: the amount out of 100, in the display's sixteenths. */
static function rg_shade_darkness(amount:Int):Void { shade_steps = whole_sixteenths(amount); }

/* A light that shows nothing outside it (Nodes::ShadeOutside#shuts_out, Framebuffer#outside_light): the same amount,
 * which is then only on (more than no sixteenths) or off, and the rest of each row shows the colour of nothing drawn in
 * place of the picture darkened. */
static var shade_shuts_out:Bool = false;
static function rg_shade_shut_out(amount:Int):Void {
  shade_steps = whole_sixteenths(amount);
  shade_shuts_out = true;
}

/* The filter the darkened part of the picture is read through (see through_filter in rg_screen.hx): the table darkens a
 * colour by the light's steps, and each screen row says which of its pixels are dark, a pixel being changed when
 * inverted XOR from <= x < to. The rows are worked out at the end of rg_screen_work_out_shade, which is the only place
 * the spans change. For a light that shows nothing outside it, every colour reads as the colour of nothing drawn. */
static var dim_filter:RgShownFilter = new RgShownFilter(new Vector<Int>(65536), false, new Vector<Int>(RG_SCREEN_HEIGHT * 3), false, dim_filled);
static var dim_table_steps:Int = -1; /* the steps the table was started for, or -1 for none yet */
static var dim_table_backdrop:Int = -1; /* the colour its entries hold for a light that shows nothing outside it, or -1 */

static function dim_filled(color:Int):Int {
  var made = shade_shuts_out ? dim_table_backdrop : darkened_by_display(color, shade_steps);
  dim_filter.table[color] = made + 1;
  return made;
}

/* The colour a light that shows nothing outside it shows there (Framebuffer#outside_light): the backdrop, through the
 * fade or tint in force, as the console's display keeps that colour in the table a walked fade walks. */
static function shown_backdrop():Int {
  var fade = rg_hook_fade_filter();
  if (fade == null) return backdrop;
  return through_filter(fade, backdrop);
}

/* Framebuffer#lit?, row by row: is (x, y) inside its row's span? A span that comes round the edge (left past right) is
 * lit outside [right, left), so the dark pixels are the ones within it; a span that does not is lit within [left,
 * right), so the dark ones are outside it. */
static function fill_dim_rows():Void {
  for (y in 0...RG_SCREEN_HEIGHT) {
    var left = shade_spans[y * 2];
    var right = shade_spans[y * 2 + 1];
    dim_filter.rows[y * 3] = left <= right ? left : right;
    dim_filter.rows[y * 3 + 1] = left <= right ? right : left;
    dim_filter.rows[y * 3 + 2] = left <= right ? 1 : 0;
  }
}

/* Reference#work_out_shade: every row's span from the game's own expressions, top to bottom, then the amount. */
static function rg_screen_work_out_shade():Void {
  for (row in 0...RG_SCREEN_HEIGHT) {
    shade_row = row;
    rg_game_shade_span();
  }
  shade_row = RG_SCREEN_HEIGHT;
  rg_game_shade_amount();
  fill_dim_rows();
}

/* Framebuffer#light_off=: whether the scene that just ran has the light switched off, set as the frame ends, before it
 * is shown (Reference#advance_frame). */
static var shade_off:Bool = false;
static function rg_shade_switch(on:Int):Void { shade_off = on == 0; }

/* Whether no light is darkening any of the picture. */
static function every_pixel_lit():Bool { return shade_steps == 0 || shade_off; }

/* rg_hook_dim_filter (Framebuffer#shade_outside, #lit?): nothing while no light darkens any of the picture, else the
 * filter above, its table started again when the steps are not the ones it was started for, or, for a light that shows
 * nothing outside it, when the colour of nothing drawn is not the one it holds. */
static function rg_light_dim_filter():RgShownFilter {
  if (every_pixel_lit()) return null;
  if (shade_shuts_out) {
    var shows = shown_backdrop();
    if (dim_table_backdrop != shows) dim_filter.table = new Vector<Int>(65536);
    dim_table_backdrop = shows;
  } else if (dim_table_steps != shade_steps) {
    dim_filter.table = new Vector<Int>(65536);
    dim_table_steps = shade_steps;
  }
  return dim_filter;
}
