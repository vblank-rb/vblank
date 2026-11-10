/*
 * FADES AND TINTS (Reference#exec_fade, #exec_tint and Framebuffer#faded): the display's own fade
 * toward black or white, held to a rectangle or placed in the stack, a fade that walks the
 * colours, and a tint toward a colour. A runtime feature (backends/runtime_features.rb): this file
 * is included at the end of rg_screen.c, for a game that fades or tints, so it reads the screen's
 * own state and painters as if it were written there. A game with neither builds without it.
 *
 * The screen never asks it about a pixel. It asks once a read for the colour table the finished
 * picture is read through (rg_fades_fade_filter), and once a thing painted for the table that
 * thing is painted through (rg_fades_paint_fade_for); the screen's loops then read the tables.
 */
#include "rg_fades.h"

/* What a display does to the finished picture: one effect at a time (Framebuffer#fade_to). */
static int32_t fade_white, fade_steps;
typedef enum { TINT_NONE, TINT_TOWARD, TINT_COLOR } tint_modes;
static tint_modes tint_mode;
static int32_t tint_white, tint_color, tint_steps, tint_by_display;

/* A FADE PLACED IN THE STACK, while one is in force (Reference @fade_placed): how far forward the
 * layer it sits under is among the layers the game declared, which way it fades, and how far. It
 * cannot be laid over the finished picture as the screen is read, since what is in front of its
 * line has to come through as drawn. So it is painted in as the view is rebuilt. */
typedef struct { int32_t in_force, layer_place, toward_white, steps; } fade_in_the_stack;
static fade_in_the_stack placed_fade;

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
static int32_t rg_fades_blend_held_by_fade(void) {
  if (placed_fade.in_force) return placed_fade.steps > 0;
  return target != scenery && fade_steps > 0;
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step. */
#define WALK_STEPS 256
#define WALK_PER_DISPLAY 16

/* Framebuffer#walked_toward: a fade that walks the colors, in five bits a channel, each channel
 * moved a truncated share of the way to black or white. */
static uint16_t walked_toward(uint16_t color, int32_t white, int32_t steps) {
  if (steps == 0) return color;
  /* FadeSteps.dimmed_levels, on a display that dims */
  int32_t level = steps >= WALK_STEPS ? 0 : 15 - (steps * 15) / WALK_STEPS;
  int32_t out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t c = (color >> (5 * channel)) & 0x1F;
    if (RG_CONSOLE_DIMS && !white) c = (2 * c * level + 15) / 30;
    else c = white ? c + ((31 - c) * steps) / WALK_STEPS : c - (c * steps) / WALK_STEPS;
    out |= c << (5 * channel);
  }
  return (uint16_t)out;
}

/* Framebuffer#brightened_by_display: each channel widened to eight bits and given +steps+
 * sixteenths of the headroom it has left there, then brought back to five bits. */
static uint16_t brightened_by_display(uint16_t color, int32_t steps) {
  if (steps == 0) return color;
  int32_t packed = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t shift = channel * 5, have = widened((color >> shift) & 0x1F);
    packed |= ((have + ((255 - have) * steps) / 16) >> 3) << shift;
  }
  return (uint16_t)packed;
}

/* Framebuffer#faded_by_display: the display's own fade toward black or white. */
static uint16_t faded_by_display(uint16_t color, int32_t white, int32_t steps) {
  return white ? brightened_by_display(color, steps) : darkened_by_display(color, steps);
}

/* Framebuffer#mixed and #mixed_by_display: the two shares added, and only then the fraction
 * dropped. The display mixes at eight bits a channel; a game writing tinted colors, at five. */
static uint16_t mixed(uint16_t color, int32_t toward, int32_t steps, int32_t by_display) {
  if (steps == 0) return color;
  int32_t keep = WALK_STEPS - steps, out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t have = (color >> (5 * channel)) & 0x1F, want = (toward >> (5 * channel)) & 0x1F;
    if (by_display) {
      out |= (((widened(have) * keep + widened(want) * steps) / WALK_STEPS) >> 3) << (5 * channel);
    } else {
      out |= ((have * keep + want * steps) / WALK_STEPS) << (5 * channel);
    }
  }
  return (uint16_t)out;
}

/* Framebuffer#faded, for a pixel the fade reaches (the screen asks only the pixels the filter's
 * rows say it does reach, see fill_fade_rows). */
static uint16_t color_through_fade(uint16_t color) {
  /* On the plain bitmap screen the display does a walked fade, in sixteenths. */
  if (tint_mode == TINT_TOWARD && tint_by_display) return faded_by_display(color, tint_white, tint_steps / WALK_PER_DISPLAY);
  if (tint_mode == TINT_TOWARD) return walked_toward(color, tint_white, tint_steps);
  /* The display counts in sixteenths, every sixteenth 256th, so the steps between are dropped. */
  if (tint_mode == TINT_COLOR) return mixed(color, tint_color, tint_by_display ? tint_steps - tint_steps % WALK_PER_DISPLAY : tint_steps, tint_by_display);
  return faded_by_display(color, fade_white, fade_steps);
}

/* Which part of the screen the display's fade reaches (Framebuffer#fade_steps_to's +reaches+):
 * RG_FADE_WHOLE_SCREEN, or RG_FADE_INSIDE or RG_FADE_OUTSIDE a rectangle held as left, top, right
 * and bottom, the right and bottom one past the last pixel. */
static int32_t fade_side = RG_FADE_WHOLE_SCREEN;
static int32_t fade_area[4];

/* THE FILTER THE SCREEN READS THE PICTURE THROUGH while a fade or a tint changes a colour, kept
 * until the fade or tint changes: a table of the colour each of the 65536 values a cell can hold is
 * shown as, and for a fade held to a rectangle each screen row's span.
 *
 * Framebuffer#fade_reaches?, row by row: a pixel is changed when +inverted+ XOR
 * from <= x < to. Inside the rectangle that is the rectangle's columns on its rows and nothing on
 * the others; outside it is the opposite. A tint reaches every pixel whatever rectangle a fade
 * before it was held to. */
static shown_filter fade_filter;
static uint16_t fade_table[65536];
static int32_t fade_rows[RG_SCREEN_HEIGHT][3];
static int32_t fade_filter_stale = 1;

static void fill_fade_rows(void) {
  fade_filter.everywhere = tint_mode != TINT_NONE || fade_side == RG_FADE_WHOLE_SCREEN;
  if (fade_filter.everywhere) return;
  int32_t inverted = fade_side == RG_FADE_OUTSIDE;
  for (int32_t y = 0; y < RG_SCREEN_HEIGHT; y++) {
    int32_t on_rows = y >= fade_area[1] && y < fade_area[3];
    fade_rows[y][0] = on_rows ? fade_area[0] : 0;
    fade_rows[y][1] = on_rows ? fade_area[2] : 0;
    fade_rows[y][2] = inverted;
  }
}

/* rg_hook_fade_filter. Nothing when no tint is in force and the fade is not out of nought steps:
 * the picture is then read as it is stored, which keeps a cell's bit 15 that every fade drops.
 * A tint in force always has a filter, even for a tint of nought steps (which changes no colour):
 * the see-through cells it remixes are read through it (Framebuffer#shown_color). */
static const shown_filter *rg_fades_fade_filter(void) {
  if (tint_mode == TINT_NONE && fade_steps == 0) return NULL;
  if (fade_filter_stale) {
    for (uint32_t color = 0; color < 65536; color++) fade_table[color] = color_through_fade((uint16_t)color);
    fade_filter.table = fade_table;
    fade_filter.rows = fade_rows;
    fill_fade_rows();
    fade_filter_stale = 0;
  }
  /* Framebuffer#shown_color: a cell a see-through layer was mixed into, under a tint, is mixed
   * again from its two colors tinted: a tint on a screen drawn through a color table moves the
   * colors the display then mixes, so it reaches each side before the two are added, and past a
   * whole the order shows. */
  fade_filter.remix = tint_mode != TINT_NONE && pixels == viewed;
  return &fade_filter;
}

/* THE TABLE A PLACED FADE PAINTS THROUGH (rg_hook_paint_fade_for), made again when the fade's
 * direction or steps are not the ones it was made for. */
static uint16_t placed_fade_table[65536];
static int32_t placed_table_toward_white = -1, placed_table_steps = -1;

/* Reference#set_blend_for, the fade half, for the thing about to be painted: the placed fade in
 * force reaches it unless that fade's layer is no further forward than +fade_place+, which is
 * the furthest forward such a layer can be and still leave the thing as drawn (RG_BG_FADE_PLACE).
 * That is RG_NO_LAYER for a thing every placed fade reaches, and for the backdrop, which is
 * behind everything. A fade under a layer the game never declared reaches everything. A color
 * painted through the table is Framebuffer#apply_placed_fade's; a fade of nought steps changes
 * none, so it answers no table. */
static const uint16_t *rg_fades_paint_fade_for(int32_t fade_place) {
  int32_t under = placed_fade.layer_place;
  int32_t left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under;
  if (!placed_fade.in_force || left_as_drawn || placed_fade.steps == 0) return NULL;
  if (placed_table_toward_white != placed_fade.toward_white || placed_table_steps != placed_fade.steps) {
    for (uint32_t color = 0; color < 65536; color++)
      placed_fade_table[color] = faded_by_display((uint16_t)color, placed_fade.toward_white, placed_fade.steps);
    placed_table_toward_white = placed_fade.toward_white;
    placed_table_steps = placed_fade.steps;
  }
  return placed_fade_table;
}

static int32_t tint_mixed_by_display(void);

/* Reference#exec_fade, through Framebuffer#fade_steps_to or, for a fade that walks the colors,
 * #tint_steps_to. +placed+ is 1 for a fade placed in the stack under the layer at +layer_place+.
 *
 * Over the whole screen it is laid over the picture as the screen is read, so nothing drawn
 * changes. Placed in the stack it is painted into the picture, so the picture is built again
 * right here, and again by the fade that takes a placed one's place, which has to take it back
 * out.
 *
 * A fade that takes the display's blend takes it from a see-through layer and hands it back as
 * it lifts, so the picture is built again at each of those two moments as well: the layer is
 * solid on one side of them and see-through on the other. */
static void fade_to(int32_t placed, int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked) {
  int32_t took_the_blend = rg_fades_blend_held_by_fade(), was_placed = placed_fade.in_force;
  placed_fade = (fade_in_the_stack){.in_force = placed, .layer_place = layer_place, .toward_white = toward_white, .steps = steps};
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    tint_by_display = tint_mixed_by_display(); /* Reference#fade_by_tint */
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  fade_filter_stale = 1;
  int32_t blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() != took_the_blend;
  if (was_placed || placed || blend_changed_hands) request_repaint();
}

void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

void rg_screen_fade_in_area(int32_t reaches, int32_t left, int32_t top, int32_t right, int32_t bottom,
                            int32_t toward_white, int32_t steps) {
  fade_side = reaches;
  fade_area[0] = left;
  fade_area[1] = top;
  fade_area[2] = right;
  fade_area[3] = bottom;
  fade_to(0, RG_NO_LAYER, toward_white, steps, 0);
}

void rg_screen_fade_under(int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain
 * bitmap screen does, on a console that blends? Every other screen has it mixed into a colour
 * table. */
static int32_t tint_mixed_by_display(void) { return painted_screen() && pixels == viewed && RG_CONSOLE_BLENDS; }

/* rg_hook_screen_set (Reference#exec_screen): a tint in force is mixed this screen's way. */
static void rg_fades_screen_set(void) {
  tint_by_display = tint_mixed_by_display();
  fade_filter_stale = 1;
}

/* Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever
 * fade was in force, one placed in the stack included. A fade that goes may have been holding a
 * see-through layer solid, or have been painted into the picture, so the picture is built again
 * when one does. */
void rg_screen_tint(int32_t color, int32_t steps) {
  int32_t took_the_blend = rg_fades_blend_held_by_fade(), was_placed = placed_fade.in_force;
  placed_fade.in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  tint_by_display = tint_mixed_by_display();
  fade_steps = 0;
  fade_filter_stale = 1;
  int32_t blend_changed_hands = see_through_layers() > 0 && rg_fades_blend_held_by_fade() != took_the_blend;
  if (was_placed || blend_changed_hands) request_repaint();
}

/* rg_hook_visit_state: the fade, the tint, a fade placed in the stack and where the fade reaches
 * (Computer::StateFields "fades"). The tables are made again from them as the picture is next read. */
static void rg_fades_visit_state(void) {
  int64_t numbers[] = {
    fade_white, fade_steps, tint_mode, tint_white, tint_color, tint_steps, tint_by_display,
    placed_fade.in_force, placed_fade.layer_place, placed_fade.toward_white, placed_fade.steps,
    fade_side, fade_area[0], fade_area[1], fade_area[2], fade_area[3],
  };
  rg_state_numbers("fades", numbers, (int32_t)(sizeof numbers / sizeof numbers[0]));
  if (numbers[2] < 0 || numbers[2] > (int64_t)TINT_COLOR)
    rg_state_refuse_damaged("the screen names a tint it does not have");
  fade_white = (int32_t)numbers[0], fade_steps = (int32_t)numbers[1], tint_mode = (tint_modes)numbers[2];
  tint_white = (int32_t)numbers[3], tint_color = (int32_t)numbers[4], tint_steps = (int32_t)numbers[5];
  tint_by_display = (int32_t)numbers[6];
  placed_fade = (fade_in_the_stack){(int32_t)numbers[7], (int32_t)numbers[8], (int32_t)numbers[9], (int32_t)numbers[10]};
  fade_side = (int32_t)numbers[11];
  for (int32_t i = 0; i < 4; i++) fade_area[i] = (int32_t)numbers[12 + i];
  fade_filter_stale = 1;
}

/* Backends::FadeSteps.steps */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked) {
  int32_t levels = walked ? WALK_STEPS : 16;
  if (fraction_bits < 0) {
    int32_t sixteenths = whole_sixteenths(amount);
    return walked ? sixteenths * WALK_PER_DISPLAY : sixteenths;
  }
  return clamp32(floor_div((int64_t)amount * levels, (int64_t)100 << fraction_bits), 0, levels);
}
