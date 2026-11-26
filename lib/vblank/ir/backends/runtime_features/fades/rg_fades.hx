/*
 * Fades and tints (Reference#exec_fade, #exec_tint and Framebuffer#faded): the display's own fade toward black or white,
 * held to a rectangle or placed in the stack, a fade that walks the colours, and a tint toward a colour. A port of the
 * JavaScript runtime's rg_fades.js, function for function (rg_fades.c says how, rule for rule). A runtime feature
 * (backends/runtime_features.rb), joined into the runtime after rg_screen.hx for a game that fades or tints, so it
 * reads the screen's own state and painters as if it were written there.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table the finished picture is read
 * through (rg_fades_fade_filter), and once a thing painted for the table that thing is painted through
 * (rg_fades_paint_fade_for); the screen's loops then read the tables.
 *
 * The tables are filled as colours are looked up, not all at once: a fade that animates has a new state every frame,
 * and working out sixty-five thousand colours a frame costs more than the reading it saves. A table holds the colour
 * shown plus one, so a colour not looked up yet is 0 (a new table is a new vector, which a movie zeroes itself), and the
 * table's +fill+ works it out, stores it and answers it. Every change of state starts its table again.
 *
 * Left out: the state image (rg_fades_visit_state refuses it).
 */

static inline var RG_FADE_WHOLE_SCREEN:Int = 0;
static inline var RG_FADE_INSIDE:Int = 1;
static inline var RG_FADE_OUTSIDE:Int = 2;

/* What a display does to the finished picture: one effect at a time (Framebuffer#fade_to). */
static var fade_white:Int = 0;
static var fade_steps:Int = 0;
static inline var TINT_NONE:Int = 0;
static inline var TINT_TOWARD:Int = 1;
static inline var TINT_COLOR:Int = 2;
static var tint_mode:Int = TINT_NONE;
static var tint_white:Int = 0;
static var tint_color:Int = 0;
static var tint_steps:Int = 0;
static var tint_by_display:Int = 0;

/* A fade placed in the stack, while one is in force (Reference @fade_placed): how far forward the layer it sits under
 * is among the layers the game declared, which way it fades, and how far. It cannot be laid over the finished picture
 * as the screen is read, since what is in front of its line has to come through as drawn. So it is painted in as the
 * view is rebuilt. */
static var placed_in_force:Int = 0;
static var placed_layer_place:Int = RG_NO_LAYER;
static var placed_toward_white:Int = 0;
static var placed_steps:Int = 0;

/* Reference#fading?: is a fade in force that takes the display's blend? The display blends two layers together or
 * moves the whole picture toward a color, one or the other, so while such a fade runs a see-through layer is solid. A
 * fade that walks the colors sets no fade amount and is never found here. The copy of the scenery kept to put back
 * under sprites is a picture of its own, which no fade was ever set on, so painting into it never finds one either.
 *
 * A fade placed in the stack is the game's and not either picture's, and takes the blend whichever is being painted.
 *
 * The screen asks it when a thing in a see-through layer is about to be painted (rg_hook_blend_held_by_fade, in
 * mix_as_layer). */
static function rg_fades_blend_held_by_fade():Bool {
  if (placed_in_force != 0) return placed_steps > 0;
  return target != scenery && fade_steps > 0;
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step. */
static inline var WALK_STEPS:Int = 256;
static inline var WALK_PER_DISPLAY:Int = 16;

/* Framebuffer#walked_toward */
static function walked_toward(color:Int, white:Int, steps:Int):Int {
  if (steps == 0) return color;
  /* FadeSteps.dimmed_levels, on a display that dims */
  var level = steps >= WALK_STEPS ? 0 : 15 - Std.int((steps * 15) / WALK_STEPS);
  var out = 0;
  for (channel in 0...3) {
    var c = (color >> (5 * channel)) & 0x1F;
    if (RG_CONSOLE_DIMS != 0 && white == 0) c = Std.int((2 * c * level + 15) / 30);
    else c = white != 0 ? c + Std.int(((31 - c) * steps) / WALK_STEPS) : c - Std.int((c * steps) / WALK_STEPS);
    out |= c << (5 * channel);
  }
  return out & 0xFFFF;
}

/* Framebuffer#brightened_by_display */
static function brightened_by_display(color:Int, steps:Int):Int {
  if (steps == 0) return color;
  var packed = 0;
  for (channel in 0...3) {
    var shift = channel * 5;
    var have = widened((color >> shift) & 0x1F);
    packed |= ((have + Std.int(((255 - have) * steps) / 16)) >> 3) << shift;
  }
  return packed;
}

/* Framebuffer#faded_by_display: the display's own fade toward black or white. */
static function faded_by_display(color:Int, white:Int, steps:Int):Int {
  return white != 0 ? brightened_by_display(color, steps) : darkened_by_display(color, steps);
}

/* Framebuffer#mixed and #mixed_by_display */
static function mixed(color:Int, toward:Int, steps:Int, by_display:Int):Int {
  if (steps == 0) return color;
  var keep = WALK_STEPS - steps;
  var out = 0;
  for (channel in 0...3) {
    var have = (color >> (5 * channel)) & 0x1F;
    var want = (toward >> (5 * channel)) & 0x1F;
    if (by_display != 0) {
      out |= (Std.int((widened(have) * keep + widened(want) * steps) / WALK_STEPS) >> 3) << (5 * channel);
    } else {
      out |= Std.int((have * keep + want * steps) / WALK_STEPS) << (5 * channel);
    }
  }
  return out & 0xFFFF;
}

/* Framebuffer#faded, for a pixel the fade reaches (the screen asks only the pixels the filter's rows say it does
 * reach, see fill_fade_rows). */
static function color_through_fade(color:Int):Int {
  if (tint_mode == TINT_TOWARD && tint_by_display != 0) return faded_by_display(color, tint_white, Std.int(tint_steps / WALK_PER_DISPLAY));
  if (tint_mode == TINT_TOWARD) return walked_toward(color, tint_white, tint_steps);
  if (tint_mode == TINT_COLOR) return mixed(color, tint_color, tint_by_display != 0 ? tint_steps - (tint_steps % WALK_PER_DISPLAY) : tint_steps, tint_by_display);
  return faded_by_display(color, fade_white, fade_steps);
}

/* Which part of the screen the display's fade reaches (Framebuffer#fade_steps_to's +reaches+): RG_FADE_WHOLE_SCREEN, or
 * RG_FADE_INSIDE or RG_FADE_OUTSIDE a rectangle held as left, top, right and bottom, the right and bottom one past the
 * last pixel. */
static var fade_side:Int = RG_FADE_WHOLE_SCREEN;
static var fade_area:Vector<Int> = new Vector<Int>(4);

/* The filter the screen reads the picture through while a fade or a tint changes a colour (see rg_screen_shown), kept
 * until the fade or tint changes: the table of the colour each value a cell can hold is shown as, and for a fade held
 * to a rectangle each screen row's span.
 *
 * Framebuffer#fade_reaches?, row by row: a pixel is changed when inverted XOR from <= x < to. Inside the rectangle that
 * is the rectangle's columns on its rows and nothing on the others; outside it is the opposite. A tint reaches every
 * pixel whatever rectangle a fade before it was held to. */
static var fade_filter:RgShownFilter = new RgShownFilter(new Vector<Int>(65536), true, new Vector<Int>(RG_SCREEN_HEIGHT * 3), false, fade_filled);
static var fade_filter_stale:Bool = true;

static function fade_filled(color:Int):Int {
  var made = color_through_fade(color);
  fade_filter.table[color] = made + 1;
  return made;
}

static function fill_fade_rows():Void {
  fade_filter.everywhere = tint_mode != TINT_NONE || fade_side == RG_FADE_WHOLE_SCREEN;
  if (fade_filter.everywhere) return;
  var inverted = fade_side == RG_FADE_OUTSIDE ? 1 : 0;
  for (y in 0...RG_SCREEN_HEIGHT) {
    var on_rows = y >= fade_area[1] && y < fade_area[3];
    fade_filter.rows[y * 3] = on_rows ? fade_area[0] : 0;
    fade_filter.rows[y * 3 + 1] = on_rows ? fade_area[2] : 0;
    fade_filter.rows[y * 3 + 2] = inverted;
  }
}

/* rg_hook_fade_filter. Nothing when no tint is in force and the fade is not out of nought steps: the picture is then
 * read as it is stored, which keeps a cell's bit 15 that every fade drops. A tint in force always has a filter, even
 * for a tint of nought steps (which changes no colour): the see-through cells it remixes are read through it
 * (Framebuffer#shown_color). */
static function rg_fades_fade_filter():RgShownFilter {
  if (tint_mode == TINT_NONE && fade_steps == 0) return null;
  if (fade_filter_stale) {
    fade_filter.table = new Vector<Int>(65536);
    fill_fade_rows();
    fade_filter_stale = false;
  }
  /* Framebuffer#shown_color: a cell a see-through layer was mixed into, under a tint, is mixed again from its two
   * colors tinted: a tint on a screen drawn through a color table moves the colors the display then mixes, so it reaches
   * each side before the two are added, and past a whole the order shows. */
  fade_filter.remix = tint_mode != TINT_NONE && pixels == viewed;
  return fade_filter;
}

/* The table a placed fade paints through (rg_hook_paint_fade_for), started again when the fade's direction or steps are
 * not the ones it was made for. */
static var placed_fade_filter:RgShownFilter = new RgShownFilter(new Vector<Int>(65536), true, new Vector<Int>(0), false, placed_fade_filled);
static var placed_table_toward_white:Int = -1;
static var placed_table_steps:Int = -1;

static function placed_fade_filled(color:Int):Int {
  var made = faded_by_display(color, placed_toward_white, placed_steps);
  placed_fade_filter.table[color] = made + 1;
  return made;
}

/* Reference#set_blend_for, the fade half, for the thing about to be painted: the placed fade in force reaches it unless
 * that fade's layer is no further forward than +fade_place+, which is the furthest forward such a layer can be and
 * still leave the thing as drawn (RG_BG_FADE_PLACE). That is RG_NO_LAYER for a thing every placed fade reaches, and for
 * the backdrop, which is behind everything. A fade under a layer the game never declared reaches everything. A color
 * painted through the table is Framebuffer#apply_placed_fade's; a fade of nought steps changes none, so it answers no
 * table. */
static function rg_fades_paint_fade_for(fade_place:Int):RgShownFilter {
  var under = placed_layer_place;
  var left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under;
  if (placed_in_force == 0 || left_as_drawn || placed_steps == 0) return null;
  if (placed_table_toward_white != placed_toward_white || placed_table_steps != placed_steps) {
    placed_fade_filter.table = new Vector<Int>(65536);
    placed_table_toward_white = placed_toward_white;
    placed_table_steps = placed_steps;
  }
  return placed_fade_filter;
}

static function rg_fades_visit_state():Void { rg_state_refuse(); }

/* Reference#exec_fade, through Framebuffer#fade_steps_to or #tint_steps_to */
static function fade_to(placed:Int, layer_place:Int, toward_white:Int, steps:Int, walked:Int):Void {
  var took_the_blend = rg_fades_blend_held_by_fade();
  var was_placed = placed_in_force;
  placed_in_force = placed;
  placed_layer_place = layer_place;
  placed_toward_white = toward_white;
  placed_steps = steps;
  if (walked != 0) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    tint_by_display = tint_mixed_by_display();
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed != 0 ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  fade_filter_stale = true;
  var blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() != took_the_blend;
  if (was_placed != 0 || placed != 0 || blend_changed_hands) request_repaint();
}

static function rg_screen_fade(toward_white:Int, steps:Int, walked:Int):Void {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

static function rg_screen_fade_in_area(reaches:Int, left:Int, top:Int, right:Int, bottom:Int, toward_white:Int, steps:Int):Void {
  fade_side = reaches;
  fade_area[0] = left;
  fade_area[1] = top;
  fade_area[2] = right;
  fade_area[3] = bottom;
  fade_to(0, RG_NO_LAYER, toward_white, steps, 0);
}

static function rg_screen_fade_under(layer_place:Int, toward_white:Int, steps:Int, walked:Int):Void {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#lift_placed_fade_for_light: a light that takes turns takes a placed fade off on the pass of a scene it is on
 * in, where every other scene leaves a fade as the game set it. +on+ is the light's switch as the scene that ran set
 * it. */
static function rg_lift_placed_fade_for_light(on:Int):Void {
  if (on == 0 || placed_in_force == 0) return;
  placed_in_force = 0;
  request_repaint();
}

/* Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain bitmap screen does, on
 * a console that blends? Every other screen has it mixed into a colour table. */
static function tint_mixed_by_display():Int { return painted_screen() && pixels == viewed && RG_CONSOLE_BLENDS != 0 ? 1 : 0; }

/* rg_hook_screen_set (Reference#exec_screen): a tint in force is mixed this screen's way. */
static function rg_fades_screen_set():Void {
  tint_by_display = tint_mixed_by_display();
  fade_filter_stale = true;
}

/* Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever fade was in force, one
 * placed in the stack included. */
static function rg_screen_tint(color:Int, steps:Int):Void {
  var took_the_blend = rg_fades_blend_held_by_fade();
  var was_placed = placed_in_force;
  placed_in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  tint_by_display = tint_mixed_by_display();
  fade_steps = 0;
  fade_filter_stale = true;
  var blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() != took_the_blend;
  if (was_placed != 0 || blend_changed_hands) request_repaint();
}

/* Backends::FadeSteps.steps: a game's amount is worked out as a float. */
static function rg_fade_steps(amount:Int, fraction_bits:Int, walked:Int):Int {
  var levels = walked != 0 ? WALK_STEPS : 16;
  if (fraction_bits < 0) {
    var sixteenths = whole_sixteenths(amount);
    return walked != 0 ? sixteenths * WALK_PER_DISPLAY : sixteenths;
  }
  var scaled:Float = amount;
  var share = rg_floor(scaled * levels / (100.0 * Math.pow(2, fraction_bits)));
  return share < 0 ? 0 : (share > levels ? levels : Std.int(share));
}
