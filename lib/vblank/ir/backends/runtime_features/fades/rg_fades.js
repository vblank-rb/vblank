/*
 * FADES AND TINTS (Reference#exec_fade, #exec_tint and Framebuffer#faded): the display's own fade
 * toward black or white, held to a rectangle or placed in the stack, a fade that walks the
 * colours, and a tint toward a colour. A runtime feature (backends/runtime_features.rb), joined
 * into the runtime's script after rg_screen.js for a game that fades or tints, so it reads the
 * screen's own state and painters as if it were written there. rg_fades.c says how, rule for
 * rule; this is that file written again, function for function.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table the finished
 * picture is read through (rg_fades_fade_filter), and once a thing painted for the table that
 * thing is painted through (rg_fades_paint_fade_for); the screen's loops then read the tables.
 *
 * The tables are filled as colours are looked up, not all at once as C does: a fade that animates
 * has a new state every frame, and working out sixty-five thousand colours a frame costs more than
 * the reading it saves. A colour not looked up yet is -1 in its table, and the table's +fill+ works
 * it out, stores it and answers it. Every change of state starts its table again.
 */

const RG_FADE_WHOLE_SCREEN = 0, RG_FADE_INSIDE = 1, RG_FADE_OUTSIDE = 2;

/* What a display does to the finished picture: one effect at a time (Framebuffer#fade_to). */
let fade_white = 0, fade_steps = 0;
const TINT_NONE = 0, TINT_TOWARD = 1, TINT_COLOR = 2;
let tint_mode = TINT_NONE;
let tint_white = 0, tint_color = 0, tint_steps = 0, tint_by_display = 0;

/* A FADE PLACED IN THE STACK, while one is in force (Reference @fade_placed): how far forward the
 * layer it sits under is among the layers the game declared, which way it fades, and how far. It
 * cannot be laid over the finished picture as the screen is read, since what is in front of its
 * line has to come through as drawn. So it is painted in as the view is rebuilt. */
let placed_fade = { in_force: 0, layer_place: RG_NO_LAYER, toward_white: 0, steps: 0 };

/* Reference#fading?: is a fade in force that takes the display's blend? The display blends two
 * layers together or moves the whole picture toward a color, one or the other, so while such a
 * fade runs a see-through layer is solid. A fade that walks the colors sets no fade amount and
 * is never found here. The copy of the scenery kept to put back under sprites is a picture of
 * its own, which no fade was ever set on, so painting into it never finds one either.
 *
 * A fade placed in the stack is the game's and not either picture's, and takes the blend
 * whichever is being painted.
 *
 * The screen asks it when a thing in a see-through layer is about to be painted
 * (rg_hook_blend_held_by_fade, in mix_as_layer). */
function rg_fades_blend_held_by_fade() {
  if (placed_fade.in_force) return placed_fade.steps > 0;
  return target !== scenery && fade_steps > 0;
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step. */
const WALK_STEPS = 256;
const WALK_PER_DISPLAY = 16;

/* Framebuffer#walked_toward */
function walked_toward(color, white, steps) {
  if (steps === 0) return color;
  /* FadeSteps.dimmed_levels, on a display that dims */
  const level = steps >= WALK_STEPS ? 0 : 15 - Math.trunc((steps * 15) / WALK_STEPS);
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    let c = (color >> (5 * channel)) & 0x1F;
    if (RG_CONSOLE_DIMS && !white) c = Math.trunc((2 * c * level + 15) / 30);
    else c = white ? c + Math.trunc(((31 - c) * steps) / WALK_STEPS) : c - Math.trunc((c * steps) / WALK_STEPS);
    out |= c << (5 * channel);
  }
  return out & 0xFFFF;
}

/* Framebuffer#brightened_by_display */
function brightened_by_display(color, steps) {
  if (steps === 0) return color;
  let packed = 0;
  for (let channel = 0; channel < 3; channel++) {
    const shift = channel * 5, have = widened((color >> shift) & 0x1F);
    packed |= ((have + Math.trunc(((255 - have) * steps) / 16)) >> 3) << shift;
  }
  return packed;
}

/* Framebuffer#faded_by_display: the display's own fade toward black or white. */
function faded_by_display(color, white, steps) {
  return white ? brightened_by_display(color, steps) : darkened_by_display(color, steps);
}

/* Framebuffer#mixed and #mixed_by_display */
function mixed(color, toward, steps, by_display) {
  if (steps === 0) return color;
  const keep = WALK_STEPS - steps;
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    const have = (color >> (5 * channel)) & 0x1F, want = (toward >> (5 * channel)) & 0x1F;
    if (by_display) {
      out |= (Math.trunc((widened(have) * keep + widened(want) * steps) / WALK_STEPS) >> 3) << (5 * channel);
    } else {
      out |= Math.trunc((have * keep + want * steps) / WALK_STEPS) << (5 * channel);
    }
  }
  return out & 0xFFFF;
}

/* Framebuffer#faded, for a pixel the fade reaches (the screen asks only the pixels the filter's
 * rows say it does reach, see fill_fade_rows). */
function color_through_fade(color) {
  if (tint_mode === TINT_TOWARD && tint_by_display) return faded_by_display(color, tint_white, Math.trunc(tint_steps / WALK_PER_DISPLAY));
  if (tint_mode === TINT_TOWARD) return walked_toward(color, tint_white, tint_steps);
  if (tint_mode === TINT_COLOR) return mixed(color, tint_color, tint_by_display ? tint_steps - (tint_steps % WALK_PER_DISPLAY) : tint_steps, tint_by_display);
  return faded_by_display(color, fade_white, fade_steps);
}

/* Which part of the screen the display's fade reaches (Framebuffer#fade_steps_to's +reaches+):
 * RG_FADE_WHOLE_SCREEN, or RG_FADE_INSIDE or RG_FADE_OUTSIDE a rectangle held as left, top, right
 * and bottom, the right and bottom one past the last pixel. */
let fade_side = RG_FADE_WHOLE_SCREEN;
const fade_area = [0, 0, 0, 0];

/* THE FILTER THE SCREEN READS THE PICTURE THROUGH while a fade or a tint changes a colour (see
 * shown_filter in rg_screen.js), kept until the fade or tint changes: the table of the colour each
 * value a cell can hold is shown as, and for a fade held to a rectangle each screen row's span.
 *
 * Framebuffer#fade_reaches?, row by row: a pixel is changed when inverted XOR from <= x < to. Inside
 * the rectangle that is the rectangle's columns on its rows and nothing on the others; outside it
 * is the opposite. A tint reaches every pixel whatever rectangle a fade before it was held to. */
const fade_filter = {
  table: new Int32Array(65536).fill(-1),
  everywhere: true,
  rows: new Int32Array(RG_SCREEN_HEIGHT * 3),
  remix: false,
  fill(color) { return (this.table[color] = color_through_fade(color)); },
};
let fade_filter_stale = true;

function fill_fade_rows() {
  fade_filter.everywhere = tint_mode !== TINT_NONE || fade_side === RG_FADE_WHOLE_SCREEN;
  if (fade_filter.everywhere) return;
  const inverted = fade_side === RG_FADE_OUTSIDE ? 1 : 0;
  for (let y = 0; y < RG_SCREEN_HEIGHT; y++) {
    const on_rows = y >= fade_area[1] && y < fade_area[3];
    fade_filter.rows[y * 3] = on_rows ? fade_area[0] : 0;
    fade_filter.rows[y * 3 + 1] = on_rows ? fade_area[2] : 0;
    fade_filter.rows[y * 3 + 2] = inverted;
  }
}

/* rg_hook_fade_filter. Nothing when no tint is in force and the fade is not out of nought steps:
 * the picture is then read as it is stored, which keeps a cell's bit 15 that every fade drops.
 * A tint in force always has a filter, even for a tint of nought steps (which changes no colour):
 * the see-through cells it remixes are read through it (Framebuffer#shown_color). */
function rg_fades_fade_filter() {
  if (tint_mode === TINT_NONE && fade_steps === 0) return null;
  if (fade_filter_stale) {
    fade_filter.table.fill(-1);
    fill_fade_rows();
    fade_filter_stale = false;
  }
  /* Framebuffer#shown_color: a cell a see-through layer was mixed into, under a tint, is mixed
   * again from its two colors tinted: a tint on a screen drawn through a color table moves the
   * colors the display then mixes, so it reaches each side before the two are added, and past a
   * whole the order shows. */
  fade_filter.remix = tint_mode !== TINT_NONE && pixels === viewed;
  return fade_filter;
}

/* THE TABLE A PLACED FADE PAINTS THROUGH (rg_hook_paint_fade_for), started again when the fade's
 * direction or steps are not the ones it was made for. */
const placed_fade_filter = {
  table: new Int32Array(65536).fill(-1),
  fill(color) { return (this.table[color] = faded_by_display(color, placed_fade.toward_white, placed_fade.steps)); },
};
let placed_table_toward_white = -1, placed_table_steps = -1;

/* Reference#set_blend_for, the fade half, for the thing about to be painted: the placed fade in
 * force reaches it unless that fade's layer is no further forward than +fade_place+, which is
 * the furthest forward such a layer can be and still leave the thing as drawn (RG_BG_FADE_PLACE).
 * That is RG_NO_LAYER for a thing every placed fade reaches, and for the backdrop, which is
 * behind everything. A fade under a layer the game never declared reaches everything. A color
 * painted through the table is Framebuffer#apply_placed_fade's; a fade of nought steps changes
 * none, so it answers no table. */
function rg_fades_paint_fade_for(fade_place) {
  const under = placed_fade.layer_place;
  const left_as_drawn = under !== RG_NO_LAYER && fade_place !== RG_NO_LAYER && fade_place >= under;
  if (!placed_fade.in_force || left_as_drawn || placed_fade.steps === 0) return null;
  if (placed_table_toward_white !== placed_fade.toward_white || placed_table_steps !== placed_fade.steps) {
    placed_fade_filter.table.fill(-1);
    placed_table_toward_white = placed_fade.toward_white;
    placed_table_steps = placed_fade.steps;
  }
  return placed_fade_filter;
}

/* rg_hook_visit_state (rg_fades.c's rg_fades_visit_state). */
function rg_fades_visit_state() {
  const numbers = [
    fade_white, fade_steps, tint_mode, tint_white, tint_color, tint_steps, tint_by_display,
    placed_fade.in_force, placed_fade.layer_place, placed_fade.toward_white, placed_fade.steps,
    fade_side, ...fade_area,
  ];
  rg_state_numbers("fades", numbers);
  if (numbers[2] < TINT_NONE || numbers[2] > TINT_COLOR)
    rg_fault("This state is damaged: the screen names a tint it does not have. Load a state that this game wrote.");
  [fade_white, fade_steps, tint_mode, tint_white, tint_color, tint_steps, tint_by_display] = numbers;
  placed_fade = { in_force: numbers[7], layer_place: numbers[8], toward_white: numbers[9], steps: numbers[10] };
  fade_side = numbers[11];
  for (let i = 0; i < 4; i++) fade_area[i] = numbers[12 + i];
  fade_filter_stale = true;
}

/* Reference#exec_fade, through Framebuffer#fade_steps_to or #tint_steps_to */
function fade_to(placed, layer_place, toward_white, steps, walked) {
  const took_the_blend = rg_fades_blend_held_by_fade(), was_placed = placed_fade.in_force;
  placed_fade = { in_force: placed, layer_place, toward_white, steps };
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    tint_by_display = tint_mixed_by_display();
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  fade_filter_stale = true;
  const blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() !== took_the_blend;
  if (was_placed || placed || blend_changed_hands) request_repaint();
}

function rg_screen_fade(toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

function rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps) {
  fade_side = reaches;
  fade_area[0] = left;
  fade_area[1] = top;
  fade_area[2] = right;
  fade_area[3] = bottom;
  fade_to(0, RG_NO_LAYER, toward_white, steps, 0);
}

function rg_screen_fade_under(layer_place, toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain
 * bitmap screen does, on a console that blends? Every other screen has it mixed into a colour
 * table. */
function tint_mixed_by_display() { return painted_screen() && pixels === viewed && RG_CONSOLE_BLENDS ? 1 : 0; }

/* rg_hook_screen_set (Reference#exec_screen): a tint in force is mixed this screen's way. */
function rg_fades_screen_set() {
  tint_by_display = tint_mixed_by_display();
  fade_filter_stale = true;
}

/* Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever
 * fade was in force, one placed in the stack included. */
function rg_screen_tint(color, steps) {
  const took_the_blend = rg_fades_blend_held_by_fade(), was_placed = placed_fade.in_force;
  placed_fade.in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  tint_by_display = tint_mixed_by_display();
  fade_steps = 0;
  fade_filter_stale = true;
  const blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() !== took_the_blend;
  if (was_placed || blend_changed_hands) request_repaint();
}

/* Backends::FadeSteps.steps */
function rg_fade_steps(amount, fraction_bits, walked) {
  const levels = walked ? WALK_STEPS : 16;
  if (fraction_bits < 0) {
    const sixteenths = whole_sixteenths(amount);
    return walked ? sixteenths * WALK_PER_DISPLAY : sixteenths;
  }
  return clamp_number(floor_div(amount * levels, 100 * 2 ** fraction_bits), 0, levels);
}
