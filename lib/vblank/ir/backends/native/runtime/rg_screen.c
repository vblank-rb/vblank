/*
 * The game's picture, drawn in software. See rg_screen.h; each function names the interpreter's
 * method it was ported from, in backends/reference.rb or reference/framebuffer.rb, because that
 * is what decides what is right here.
 *
 * What is NOT here is refused when the game is built rather than drawn wrongly (see
 * Picture#refuse_unsupported_picture!, which is the whole list): more of anything than there is
 * room for.
 *
 * A sprite's pictures and a background's tiles arrive ready to draw: which of their pixels show,
 * and the colors of each list they can be drawn with, are worked out when the game is built (see
 * native/picture.rb).
 */
#include "rg_screen.h"
#include "rg_runtime.h"
#include "rg_int32.h"

#include <stdlib.h>
#include <string.h>

enum { CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT };

/* Marks a function that only a runtime feature calls (see the hooks below). A game without that
 * feature leaves it unused, and -Werror counts an unused static function as a fault. */
#define FEATURE_ONLY __attribute__((unused))

/* TWO PAGES, OR ONE (Framebuffer#paged=). A tear-free screen is two pictures: the display shows
 * one while the game draws into the other, and they trade places between frames, so nobody ever
 * sees a half-drawn picture. Drawing always lands on +pixels+ and the viewer always reads
 * +viewed+; with one page those are the same picture. */
static uint16_t first_page[CELLS], second_page[CELLS];
static uint16_t *pixels = first_page;
static uint16_t *viewed = first_page;
static uint16_t shown[CELLS];

/* Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back
 * under a sprite (Reference#drawing_into). */
static uint16_t *target = first_page;

/* The part of the screen drawing is held inside (Framebuffer#draw_inside), when it is held, and
 * the areas in force around it, given back as each `inside` ends: a routine with an area of its
 * own can be called from inside another's. */
typedef struct { int32_t in_force; int64_t left, top, right, bottom; } drawing_area;
enum { AREAS_DEEP = 64 };
static drawing_area area, outer_areas[AREAS_DEEP];
static int32_t areas_deep;

/* Where the window onto the picture sits (Framebuffer#camera_to): screen (0, 0) shows what was
 * drawn at (camera_x, camera_y). Nothing drawn moves. */
static int32_t camera_x, camera_y;

/* The patches of picture saved under bitmap sprites, by buffer number (Reference @backing): each
 * cell a color, or NO_CELL where the patch hung off what could be read. Nothing until the first
 * save. */
enum { NO_CELL = -1 };
static int32_t **saved_patches;
static int32_t patches_room;

/* THE SCENERY WITH NOTHING ON IT (Reference @scene_fb): the backdrop and every background up,
 * painted once and kept. A sprite on a picture that is not rebuilt every frame is drawn straight
 * onto it, so before it is drawn somewhere new the patch it covered is put back from here. Made
 * again whenever the scenery changes. */
static uint16_t scenery[RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT];
static int32_t scenery_kept;

/* The background tiles' pixels the picture is drawn from: the game's own, which cannot be
 * written, or for a game with tiles read from the file it is handed as it starts, a copy of them
 * with those tiles filled in (rg_screen_tile_pixels_to_fill). */
static const uint16_t *tile_pixels_drawn = rg_game_tile_pixels;
static uint16_t *tile_pixels_filled;

uint16_t *rg_screen_tile_pixels_to_fill(int32_t count) {
  if (!tile_pixels_filled) {
    tile_pixels_filled = malloc((size_t)(count > 0 ? count : 1) * sizeof *tile_pixels_filled);
    if (!tile_pixels_filled) rg_fault("there is no room for the %d pixels of the background tiles", (int)count);
    memcpy(tile_pixels_filled, rg_game_tile_pixels, (size_t)count * sizeof *tile_pixels_filled);
    tile_pixels_drawn = tile_pixels_filled;
  }
  return tile_pixels_filled;
}

/* The pixels of the images sprites, blits and faces draw: the game's own, which cannot be written,
 * or for a game with images read from the file it is handed as it starts, a copy of them with those
 * images filled in (rg_screen_image_pixels_to_fill). */
static const int16_t *image_pixels_drawn = rg_game_image_pixels;
static int16_t *image_pixels_filled;

int16_t *rg_screen_image_pixels_to_fill(int32_t count) {
  if (!image_pixels_filled) {
    image_pixels_filled = malloc((size_t)(count > 0 ? count : 1) * sizeof *image_pixels_filled);
    if (!image_pixels_filled) rg_fault("there is no room for the %d pixels of the pictures", (int)count);
    memcpy(image_pixels_filled, rg_game_image_pixels, (size_t)count * sizeof *image_pixels_filled);
    image_pixels_drawn = image_pixels_filled;
  }
  return image_pixels_filled;
}

static int32_t held;            /* switched off until the first frame (Framebuffer#held=) */
static int32_t frames_begun;    /* a frame boundary has been reached (Reference @uses_frames) */
static int32_t kind = -1;       /* the kind of screen up; none before the first `screen` */
static int32_t owed;            /* a rebuild of the whole view is owed (Reference#request_repaint) */
static int32_t repaints_painted;   /* how many times the whole view was built again (rg_screen_repaints_painted) */
/* The interpreter asks for a rebuild every time the scroll or the sprites are set. Here a setting
 * that moved nothing asks for nothing and only notes that it would have (rebuild_skipped), since
 * the picture is the one a rebuild would paint. That stops being so once the picture is touched:
 * something else has written to it, or the pages have changed over. So when the rebuild would be
 * painted, a skipped one with the picture touched is painted after all, whichever came first. */
static int32_t rebuild_skipped;
static int32_t picture_touched;
static int32_t backdrop;        /* the colour shown wherever nothing is drawn (Reference @backdrop) */
static int32_t current_scene = -1;

/* WHAT IS PAINTED FROM HERE ON IS FADED on its way in (Framebuffer @paint_toward), by the placed
 * fade in force: the colour table each colour goes through, or NULL to paint as drawn. Set only
 * while the view is rebuilt, for the things that fade reaches (fade_unless_left_as_drawn). */
static const uint16_t *paint_fade;

/* WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through):
 * so many sixteenths of what is painted, so many of what is under it. On only while one thing in
 * a see-through layer is being painted. The picture is painted back to front, so "what is
 * already there" is what the display would find directly behind the layer. */
typedef struct { int32_t painted, under; } shares;
static int32_t mixing;
static shares mixed_by;

/* THE TWO COLORS EACH MIXED CELL WAS MIXED FROM (Framebuffer @mixed_tops), for a tint that moves
 * the color table, which reaches each side before the mix (see shown_color). +is_mixed+ is nought
 * for a cell painted solid. Kept for the picture, and for the scenery kept apart to put back
 * behind a sprite (keep_scenery), so a cell put back is still a mix. A screen has one see-through
 * layer, so one set of shares serves every mixed cell. */
typedef struct {
  uint8_t is_mixed[CELLS];
  uint16_t tops[CELLS], unders[CELLS];
} mixed_sides;
static mixed_sides picture_mixes, scenery_mixes;
static shares mixed_cells_by;

/* THE PICTURE WITH NO SPRITES ON IT, kept beside the picture (Framebuffer @scenery) in a game
 * with a sprite in a see-through layer. "Mix with what is already there" is wrong for a sprite
 * over another sprite: a display puts all its sprites into one layer before it mixes anything,
 * so a see-through one is mixed with the scenery or the backdrop under it and never with a
 * sprite behind it. Every paint that is not a sprite's lands here as well as on the picture, and
 * a sprite is mixed with this. One copy, whichever page is being drawn. */
static uint16_t picture_without_sprites[CELLS];
static int32_t painting_sprite; /* what is painted from here on is a sprite's (Framebuffer @painting_sprite) */


/* A FILTER THE PICTURE IS READ THROUGH, handed over by a feature once a read (rg_hook_fade_filter,
 * rg_hook_dim_filter), so no feature is asked about a pixel. +table+ is the colour shown for each
 * of the 65536 values a cell can hold, indexed by its sixteen bits. It applies to every pixel when
 * +everywhere+; otherwise +rows+ has for each screen row [from, to, inverted], and a pixel is
 * changed when inverted XOR from <= x < to. +remix+: a cell a see-through layer was mixed into is
 * mixed again from its two sides, each read through the table (Framebuffer#shown_color). */
typedef struct {
  const uint16_t *table;
  int32_t everywhere;
  const int32_t (*rows)[3];
  int32_t remix;
} shown_filter;

/* --- the hooks a runtime feature takes ---
 *
 * A drawing feature that only some games use is a folder of its own under
 * backends/runtime_features/, and the build includes it at the END of this file only for a game
 * that uses it, so it reads this file's own state and painters. The screen calls it only through
 * these, which the same included file defines (RuntimeFeatures::HOOKS says what each is for). A
 * hook no feature takes does what the screen does without one. */
static void rg_hook_screen_set(void);                                /* a screen of a new kind is up */
static void rg_hook_screen_crossed(int32_t new_kind);                /* that screen took the old one's place */
static void rg_hook_frame_ended(void);                               /* a frame boundary is reached */
static void rg_hook_repaint_requested(void);                         /* a rebuild of the whole view is asked for */
static void rg_hook_rebuild_checked(void);                           /* an owed rebuild was painted, or none was owed */
static void rg_hook_repaint_began(void);                             /* the rebuild has cleared to the backdrop */
static void rg_hook_paint_level(int32_t level);                      /* the rebuild is at a level, before its sprites */
static void rg_hook_repaint_ending(void);                            /* the rebuild has painted every level */
static inline void rg_hook_stamp_scenery(void);                      /* the scenery up, onto the kept scenery */
static int32_t rg_hook_scenery_up(void);                             /* 1: some scenery is up */
static int32_t rg_hook_layer_holds_scenery(int32_t layer);           /* 1: scenery showing now is in that layer */
static int32_t rg_hook_scene_take_down(int32_t brings_scenery);      /* 1: scenery came down */
static inline int32_t rg_hook_block_size(void);                      /* the block scenery is painted in, 1 for none */
static int32_t rg_hook_drawn_count(void);                            /* how many sprites the game last put on screen */
static rg_drawn_sprite rg_hook_drawn_sprite(int32_t place);          /* the one at a place among them */
static int32_t rg_hook_any_sprite_kept(void);                           /* 1: some sprite is kept for a rebuild */
static const uint16_t *rg_hook_front_layer(void);                    /* the layer shown in front of the picture, or NULL */
static int32_t rg_hook_shown_plain(void);                            /* 0: a feature reads the picture its own way */
static const int64_t *rg_hook_shown_columns(void);                   /* the column each shows, or NULL for its own */
static int64_t rg_hook_shown_row(int64_t y);                         /* the row row +y+ shows */
static const shown_filter *rg_hook_fade_filter(void);                /* what a fade or tint does to the picture read, or NULL */
static const shown_filter *rg_hook_dim_filter(void);                 /* what a light does to it, or NULL */
static const uint16_t *rg_hook_paint_fade_for(int32_t fade_place);   /* the colours a placed fade paints a thing as, or NULL */
static int32_t rg_hook_blend_held_by_fade(void);                     /* 1: a fade holds the display's blend */

/* --- small arithmetic --- */

/* Division and remainder rounding DOWN, as Ruby's / and % do with a positive divisor. */
static int64_t floor_div(int64_t a, int64_t b) { return a / b - ((a % b != 0) && (a < 0)); }
static FEATURE_ONLY int64_t floor_mod(int64_t a, int64_t b) { return a - floor_div(a, b) * b; }
static int32_t clamp32(int64_t value, int32_t low, int32_t high) {
  return (int32_t)(value < low ? low : (value > high ? high : value));
}

/* --- the picture itself (Framebuffer) --- */

static int32_t on_screen(int64_t x, int64_t y) {
  return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT;
}

/* Framebuffer#paintable?: on the screen, and inside the area drawing is held to when it is. */
static int32_t paintable(int64_t x, int64_t y) {
  if (!on_screen(x, y)) return 0;
  return !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom);
}

/* Five bits of a color widened to eight by repeating its top bits underneath, so the brightest
 * stays the brightest (Framebuffer#widen_channel). */
static int32_t widened(int32_t channel) { return (channel << 3) | (channel >> 2); }

/* Framebuffer#mix_see_through: a see-through layer's color over what is under it. Each channel
 * is widened to eight bits first, its share of each side added and only then the sixteenth
 * dropped, and the answer taken back to five bits. The two shares need not add to a whole; past
 * one, a channel stops at its brightest. */
static uint16_t mixed_with_under(int32_t color, uint16_t under, shares by) {
  int32_t out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t have = widened((color >> (5 * channel)) & 0x1F), below = widened((under >> (5 * channel)) & 0x1F);
    int32_t mix = (have * by.painted + below * by.under) / 16;
    out |= ((mix > 255 ? 255 : mix) >> 3) << (5 * channel);
  }
  return (uint16_t)out;
}

/* Framebuffer#darkened_by_display: each channel widened to eight bits and placed in its own byte,
 * taken +steps+ sixteenths of the way to black there, and brought back to five bits. Done in the
 * channel's own byte as the interpreter does it, which rounds how much the first channel loses
 * down and how much the other two lose up. */
static FEATURE_ONLY uint16_t darkened_by_display(uint16_t color, int32_t steps) {
  if (steps == 0) return color;
  int64_t packed = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t shift = channel * 5;
    int64_t placed = (int64_t)widened((color >> shift) & 0x1F) << (channel * 8);
    int64_t kept = (placed - (placed * steps) / 16) >> (channel * 8);
    packed |= (kept >> 3) << shift;
  }
  return (uint16_t)packed;
}

/* Framebuffer#apply_placed_fade: a color as it is painted while a placed fade reaches it, through
 * the table the fade handed over (paint_fade). The color is masked to the sixteen bits a cell holds
 * either way. */
static uint16_t faded_as_painted(int32_t color) {
  if (!paint_fade) return (uint16_t)color;
  return paint_fade[(uint16_t)color];
}

/* The mixed sides kept for +page+: the picture being drawn into, or the scenery kept apart. NULL
 * for any other page, which is never shown with a tint and never put back. */
static mixed_sides *mixes_of(const uint16_t *page) {
  if (page == pixels) return &picture_mixes;
  return page == scenery ? &scenery_mixes : NULL;
}

/* Framebuffer#blend_into_cell: a color on its way into the cell at +at+ of +page+, which holds
 * +under+. The fade a placed fade asks for first, then the mix a see-through layer asks for. The
 * cell keeps the two colors of its mix, or stops being a mix when painted solid
 * (Framebuffer#set_pixel and #paint_row). */
static uint16_t into_cell(int32_t color, uint16_t under, const uint16_t *page, int64_t at) {
  uint16_t painted = faded_as_painted(color);
  mixed_sides *kept = mixes_of(page);
  if (kept) {
    kept->is_mixed[at] = (uint8_t)mixing;
    if (mixing) {
      kept->tops[at] = painted;
      kept->unders[at] = under;
    }
  }
  return mixing ? mixed_with_under(painted, under, mixed_by) : painted;
}

/* Reference#see_through_sprites?: is any sprite in a see-through layer? Asked for every pixel
 * painted, and the answer is the game's and never changes, so it is worked out once. */
static int32_t sprites_seen_through(void) {
  static int32_t answer = -1;
  if (answer >= 0) return answer;
  answer = 0;
  for (int32_t layer = 0; layer < rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; layer++)
    if (rg_game_see_through[layer * RG_ST_FIELDS + RG_ST_HOLDS_A_SPRITE]) answer = 1;
  return answer;
}

/* Whether the picture with no sprites on it is kept beside what is being drawn into
 * (Framebuffer#keep_scenery). The copy of the scenery kept to put back under sprites is a picture
 * of its own, which keeps none. */
static int32_t keeps_picture_without_sprites(void) { return target != scenery && sprites_seen_through(); }

/* A LAYER A FEATURE PAINTS INTO AS IT IS, while one is handed over (paint_onto_plain_layer, NULL to
 * give it back): a screen's worth of cells, each painted pixel stored whole there and nowhere else,
 * with no area, mix or fade. NULL while drawing goes to the picture, so a pixel painted then costs
 * one test. */
static uint16_t *plain_layer;

/* What a cell of a layer in front of the picture holds where nothing is in front
 * (rg_hook_front_layer): no colour is that number, since a colour is fifteen bits. */
enum { RG_NOTHING_IN_FRONT = 0x8000 };

FEATURE_ONLY static void paint_onto_plain_layer(uint16_t *layer) { plain_layer = layer; }

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. A sprite is mixed with the
 * picture as it is with no sprite on it, where that is kept, and anything else with what is already
 * in the cell. */
static void set_pixel(int64_t x, int64_t y, int32_t color) {
  if (plain_layer) {
    if (on_screen(x, y)) plain_layer[y * RG_SCREEN_WIDTH + x] = (uint16_t)color;
    return;
  }
  if (!paintable(x, y)) return;
  picture_touched = 1;
  int64_t at = y * RG_SCREEN_WIDTH + x;
  int32_t kept = keeps_picture_without_sprites();
  const uint16_t *under = kept && painting_sprite ? picture_without_sprites : target;
  uint16_t painted = into_cell(color, under[at], target, at);
  target[at] = painted;
  if (kept && !painting_sprite) picture_without_sprites[at] = painted;
}

/* Framebuffer#fill_rect: every cell of the rectangle, each through set_pixel. Walking only the
 * part on the screen paints the same cells. */
static void fill_cells(int64_t x, int64_t y, int64_t width, int64_t height, int32_t color) {
  int64_t left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  int64_t right = x + width, bottom = y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  for (int64_t py = top; py < bottom; py++)
    for (int64_t px = left; px < right; px++) set_pixel(px, py, color);
}

/* Framebuffer#clear: the whole picture, or the area drawing is held to and no more. */
static void clear_to(int32_t color) {
  if (area.in_force) {
    fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color);
    return;
  }
  picture_touched = 1;
  uint16_t painted = faded_as_painted(color);
  for (int32_t i = 0; i < CELLS; i++) target[i] = painted;
  mixed_sides *kept = mixes_of(target);
  if (kept) memset(kept->is_mixed, 0, sizeof kept->is_mixed);
  if (!keeps_picture_without_sprites()) return;
  for (int32_t i = 0; i < CELLS; i++) picture_without_sprites[i] = painted;
}

void rg_screen_clear(int32_t color) { clear_to(color); }

void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color) {
  fill_cells(x, y, width, height, color);
}

/* Reference#exec_inside: the area before is kept, to be given back by rg_screen_inside_ended. */
void rg_screen_inside(int32_t x, int32_t y, int32_t width, int32_t height) {
  if (areas_deep >= AREAS_DEEP) rg_fault("more than %d `inside` blocks are open at once", AREAS_DEEP);
  outer_areas[areas_deep++] = area;
  area = (drawing_area){1, x, y, (int64_t)x + width, (int64_t)y + height};
}

/* A frame may end between the two. The picture is read whole whatever area is open, so nothing
 * read then depends on the area; the interpreter gives the area back when a run stops inside one,
 * and here nothing is painted after a run stops. */
void rg_screen_inside_ended(void) { area = outer_areas[--areas_deep]; }

/* Reference#exec_camera */
void rg_screen_camera(int32_t x, int32_t y) {
  camera_x = x;
  camera_y = y;
}

int32_t rg_screen_camera_x(void) { return camera_x; }
int32_t rg_screen_camera_y(void) { return camera_y; }

/* Framebuffer#paged=. Going to two pages, the one drawn so far goes on being drawn into and a
 * blank one is shown, which is what the console does on the way in. Going back to one, the two
 * are the page holding the drawing. */
static void show_pages(int32_t two) {
  if (two == (pixels != viewed)) return;
  if (!two) {
    viewed = pixels;
    return;
  }
  viewed = pixels == first_page ? second_page : first_page;
  for (int32_t i = 0; i < CELLS; i++) viewed[i] = 0;
}

/* The buffer's saved patch, with room made for it the first time it is asked for. */
static int32_t **saved_patch(int32_t buffer) {
  if (buffer >= patches_room) {
    int32_t room = buffer + 1;
    saved_patches = realloc(saved_patches, (size_t)room * sizeof *saved_patches);
    if (!saved_patches) rg_fault("no memory left for the picture saved under a sprite");
    for (int32_t i = patches_room; i < room; i++) saved_patches[i] = NULL;
    patches_room = room;
  }
  return &saved_patches[buffer];
}

/* Reference#exec_save_region: the patch of the picture at (x, y), as it is stored — what is
 * really in the picture, wherever the window sits, and whatever area drawing is held to
 * (Framebuffer#stored_pixel). A cell off the screen is remembered as nothing. */
void rg_patch_save(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
  int32_t **patch = saved_patch(buffer);
  if (!*patch) *patch = malloc((size_t)width * (size_t)height * sizeof **patch);
  if (!*patch) rg_fault("no memory left for the picture saved under a sprite");
  for (int32_t row = 0; row < height; row++)
    for (int32_t col = 0; col < width; col++) {
      int64_t px = (int64_t)x + col, py = (int64_t)y + row;
      (*patch)[row * width + col] = on_screen(px, py) ? pixels[py * RG_SCREEN_WIDTH + px] : NO_CELL;
    }
}

/* Reference#exec_restore_region: a patch never saved puts nothing back, and neither does a cell
 * remembered as nothing. */
void rg_patch_restore(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
  const int32_t *patch = *saved_patch(buffer);
  if (!patch) return;
  for (int32_t row = 0; row < height; row++)
    for (int32_t col = 0; col < width; col++) {
      int32_t color = patch[row * width + col];
      if (color != NO_CELL) set_pixel((int64_t)x + col, (int64_t)y + row, color);
    }
}

void rg_screen_pixel(int32_t x, int32_t y, int32_t color) { set_pixel(x, y, color); }

/* Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. */
void rg_screen_points(int32_t x, int32_t y, int32_t color, const int16_t *points, int32_t count) {
  for (int32_t i = 0; i < count; i++) set_pixel((int64_t)x + points[2 * i], (int64_t)y + points[2 * i + 1], color);
}

/* Reference#exec_draw_digit */
void rg_screen_digit(int32_t value, int32_t x, int32_t y, int32_t color, const int16_t *points,
                     const int32_t *starts) {
  if (value < 0 || value > 9) return;
  rg_screen_points(x, y, color, points + 2 * starts[value], starts[value + 1] - starts[value]);
}

/* --- see-through layers --- */

static void request_repaint(void);
static FEATURE_ONLY void skip_repaint(void);
static void repaint_view(void);
static FEATURE_ONLY int32_t rebuilt_whole(void);

static int32_t see_through_layers(void) { return rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; }

static int32_t see_through_field(int32_t layer, int32_t field) {
  return rg_game_see_through[layer * RG_ST_FIELDS + field];
}

/* The layer the game is being asked about, when it is being asked, and the two amounts it
 * answered with. */
enum { NOBODY_ASKED = -1 };
static int32_t asked_layer = NOBODY_ASKED;
static struct { int32_t shows, behind; } answered;

int32_t rg_see_through_asked(int32_t layer) { return layer == asked_layer; }

void rg_see_through_answer(int32_t shows, int32_t behind) {
  answered.shows = shows;
  answered.behind = behind;
}

/* IR::SeeThrough.nearest_steps and .floor_steps: an amount out of 100 as sixteenths. */
static int32_t nearest_sixteenths(int32_t amount) { return clamp32(floor_div((int64_t)amount * 16 + 50, 100), 0, 16); }
static int32_t whole_sixteenths(int32_t amount) { return clamp32(floor_div((int64_t)amount * 16, 100), 0, 16); }

/* Reference#live_see_through_weights, through IR::SeeThrough.weights: a layer's two shares from
 * its amounts as the game works them out now. Given one amount, what is behind takes its share
 * rounded down and the layer whatever is left of a whole; given two, each is taken to the
 * nearest sixteenth. */
static shares shares_now(int32_t layer) {
  asked_layer = layer;
  rg_game_see_through_amounts();
  asked_layer = NOBODY_ASKED;
  if (see_through_field(layer, RG_ST_ONE_AMOUNT)) {
    int32_t under = whole_sixteenths(answered.behind);
    return (shares){16 - under, under};
  }
  return (shares){nearest_sixteenths(answered.shows), nearest_sixteenths(answered.behind)};
}

/* A layer's shares as they were at some moment, for the layers they were kept for: when the
 * rebuild now owed was asked for (Reference @owed_weights), and when the game last marked that it had
 * worked the amounts out again (@see_through_shown). */
typedef struct { int32_t kept; shares at; } kept_shares;
static kept_shares owed_shares[RG_MAX_SEE_THROUGH], told_shares[RG_MAX_SEE_THROUGH];

/* Reference#layer_has_anything?: scenery showing now (rg_hook_layer_holds_scenery), or a sprite
 * anywhere, since whether a sprite is shown is a variable too. */
static int32_t layer_holds_anything(int32_t layer) {
  return see_through_field(layer, RG_ST_HOLDS_A_SPRITE) || rg_hook_layer_holds_scenery(layer);
}

/* Reference#capture_see_through_weights. A rebuild is painted later than it is asked for, and
 * the game's variables can move in between, so the amounts a game works out are read when the
 * rebuild is asked for and the painting uses those. Only for a layer with something in it that
 * could be on screen: the others are never painted, and nothing is worked out that painting
 * would not have worked out. */
static void keep_shares_for_owed_rebuild(void) {
  for (int32_t layer = 0; layer < see_through_layers(); layer++) {
    owed_shares[layer].kept = !see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) && layer_holds_anything(layer);
    if (owed_shares[layer].kept) owed_shares[layer].at = shares_now(layer);
  }
}

static void forget_kept_shares(void) {
  for (int32_t layer = 0; layer < see_through_layers(); layer++) owed_shares[layer].kept = 0;
}

/* Reference#set_see_through_for, for scenery: mixing on for a thing in a see-through layer, off
 * for anything else. +layer+ is RG_SOLID for a thing in none. A fade that holds the display's blend
 * (rg_hook_blend_held_by_fade, Reference#fading?) leaves the layer solid. */
static FEATURE_ONLY void mix_as_layer(int32_t layer) {
  painting_sprite = 0;
  mixing = layer != RG_SOLID && !rg_hook_blend_held_by_fade();
  if (mixing) mixed_by = mixed_cells_by = owed_shares[layer].kept ? owed_shares[layer].at : shares_now(layer);
}


static void mix_nothing(void) {
  mixing = 0;
  painting_sprite = 0;
}

/* WHAT THE GAME HAS PAINTED (Reference @bitmaps, for the tiles and pictures of a run): every
 * run's pixels as places in its colors, one after another, place 0 being see-through. All nought
 * until a run's first copy, which is a run that shows nothing. Made the first time it is asked
 * for. */
enum { RUN_TILE_SIDE = 8, RUN_TILE_PIXELS = RUN_TILE_SIDE * RUN_TILE_SIDE, PLACES_IN_RUN_COLORS = 16 };
static uint8_t *painted_places;

static const int32_t *run_fields(int32_t run) { return rg_game_tile_runs + RG_RUN_FIELDS * run; }

static uint8_t *places_of(int32_t run) {
  if (!painted_places) {
    painted_places = calloc((size_t)rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1, 1);
    if (!painted_places) rg_fault("no memory for the tiles the game paints");
  }
  return painted_places + run_fields(run)[RG_RUN_PLACES];
}

/* Reference#request_repaint: a rebuild of the whole view is owed, and painted when something
 * needs the picture. Painting reads no variable of the game's, so it can wait: what a feature
 * works out from them (a bent background's lines) it works out once a pass and keeps.
 *
 * A painted screen is never built again, in a game that also has screens drawn from tiles. Its
 * picture is whatever the game painted there, and building the view from scenery would wipe it.
 * What asks while one is up is the machinery of the game's other screens, which runs every frame
 * whichever is showing. */
static void request_repaint(void) {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  rg_hook_repaint_requested();
  owed = 1;
  keep_shares_for_owed_rebuild();
}

/* A rebuild that request_repaint would have owed, left out because nothing moved. */
static FEATURE_ONLY void skip_repaint(void) {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  rebuild_skipped = 1;
}

/* Reference#exec_scroll_rows, and anything else that changes the picture without painting it:
 * all only ask. */
void rg_screen_request_rebuild(void) { request_repaint(); }

/* Reference#painted_screen?: is the screen that is up one the game paints? To the display that
 * is a single background, whatever was painted on it, so it goes into blocks whole, as it is
 * read. A screen drawn from tiles is built a thing at a time. */
static int32_t painted_screen(void) { return kind < 0 || kind == RG_BITMAP; }

/* Reference#exec_see_through: the amounts have been worked out again for the frame about to be
 * drawn. The painting reads them itself; what this owes is the picture, since one that neither
 * moves nor scrolls would otherwise keep the amounts it was painted with.
 *
 * A game that calls this is one whose whole view is rebuilt (Picture#see_through_picture_changes?),
 * so its sprites are kept for the rebuild rather than drawn once onto a picture that stays. */
void rg_see_through_told(int32_t layer) {
  shares now = shares_now(layer);
  kept_shares *told = &told_shares[layer];
  if (told->kept && told->at.painted == now.painted && told->at.under == now.under) return;
  *told = (kept_shares){1, now};
  request_repaint();
}

/* IR::Affine.matrix: one over the size, held at the largest number the matrix holds; then the
 * sine table, cos d being sin(d + 90). The numbers come from rg_game_turn_rules, which the build
 * writes from Ruby's own, so the two cannot drift. */
static FEATURE_ONLY void affine_matrix(int32_t angle, int32_t size, int64_t *turn_cos, int64_t *turn_sin) {
  int64_t scale_one = rg_game_turn_rules[0], one_th = rg_game_turn_rules[1];
  int64_t most = rg_game_turn_rules[2], least_size = rg_game_turn_rules[3];
  int64_t scale = size < least_size ? least_size : size;
  int64_t recip = scale_one * one_th / scale;
  if (recip > most) recip = most;
  *turn_cos = floor_div(rg_game_sines[angle + 90] * recip, one_th);
  *turn_sin = floor_div(rg_game_sines[angle] * recip, one_th);
}

/* --- sprites --- */

/* One picture: where its pixels start, and its size. */
typedef struct { const int16_t *pixels; int32_t width, height; } picture;

/* The images the game has painted, by image number: each one's pixels as its list last held
 * them, in the colors that image is drawn in, or nothing for an image nobody has painted
 * (Reference#store_run_picture). */
static int16_t **painted_images;

static picture picture_of(int32_t image) {
  const int32_t *info = rg_game_images + RG_IMAGE_FIELDS * image;
  const int16_t *painted = painted_images ? painted_images[image] : NULL;
  return (picture){painted ? painted : image_pixels_drawn + info[0], info[1], info[2]};
}

/* Room for one painted image's pixels, made the first time the image is painted. */
static int16_t *painted_pixels_of(int32_t image, int32_t count) {
  if (!painted_images) painted_images = calloc((size_t)rg_game_picture_sizes[RG_SIZE_IMAGES] + 1, sizeof *painted_images);
  if (painted_images && !painted_images[image]) painted_images[image] = malloc((size_t)count * sizeof(int16_t));
  if (!painted_images || !painted_images[image]) rg_fault("no memory for the pictures the game paints");
  return painted_images[image];
}

/* Reference#run_tile_places: the 64 places of tile +which+ of a run's list, row by row. Each byte
 * is two pixels, the left one in its low four bits; a byte the list does not hold reads as 0. A
 * list in the console's own form has +planes+ bit planes (Reference#planar_tile_places). */
static void read_tile_places(const rg_list *list, int32_t which, int32_t planes, uint8_t *places) {
  if (planes > 0) {
    int32_t first = which * planes * 8;
    for (int32_t pixel = 0; pixel < RUN_TILE_PIXELS; pixel++) {
      int32_t place = 0;
      for (int32_t plane = 0; plane < planes; plane++) {
        int32_t index = first + (plane / 2) * 16 + (pixel / RUN_TILE_SIDE) * 2 + plane % 2;
        int32_t byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
        place |= ((byte >> (7 - pixel % RUN_TILE_SIDE)) & 1) << plane;
      }
      places[pixel] = (uint8_t)place;
    }
    return;
  }
  for (int32_t at = 0; at < RUN_TILE_PIXELS / 2; at++) {
    int32_t index = which * (RUN_TILE_PIXELS / 2) + at;
    int32_t byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
    places[2 * at] = (uint8_t)(byte & 0x0F);
    places[2 * at + 1] = (uint8_t)(byte >> 4);
  }
}

/* Every image that is a painted picture's run made again from its places, each in its own colors. */
static void paint_run_images(int32_t run) {
  const int32_t *fields = run_fields(run);
  const uint8_t *places = places_of(run);
  int32_t area = fields[RG_RUN_WIDTH] * fields[RG_RUN_HEIGHT];
  for (int32_t i = 0; i < fields[RG_RUN_IMAGES]; i++) {
    const int32_t *shown_as = rg_game_run_images + (fields[RG_RUN_FIRST_IMAGE] + i) * RG_RUN_IMAGE_FIELDS;
    int16_t *pixels = painted_pixels_of(shown_as[0], area);
    for (int32_t at = 0; at < area; at++) pixels[at] = (int16_t)shown_as[1 + places[at]];
  }
}

/* Reference#copy_run_tiles. A run a background shows takes its tiles one after another. A run
 * that is a sprite's picture has its tiles in the order a sprite's are kept, left to right and
 * then top to bottom, and they are laid back out into the one picture (#copy_run_picture); then
 * every image that is that picture is made again from it, each in its own colors. */
void rg_tiles_copy(int32_t run, const rg_list *list) {
  const int32_t *fields = run_fields(run);
  uint8_t *places = places_of(run);
  int32_t width = fields[RG_RUN_WIDTH], height = fields[RG_RUN_HEIGHT];
  if (width == 0) {
    for (int32_t which = 0; which < fields[RG_RUN_TILES]; which++) read_tile_places(list, which, fields[RG_RUN_PLANES], places + which * RUN_TILE_PIXELS);
    return;
  }
  int32_t across = width / RUN_TILE_SIDE;
  for (int32_t which = 0; which < across * (height / RUN_TILE_SIDE); which++) {
    uint8_t tile[RUN_TILE_PIXELS];
    read_tile_places(list, which, fields[RG_RUN_PLANES], tile);
    int32_t left = (which % across) * RUN_TILE_SIDE, top = (which / across) * RUN_TILE_SIDE;
    for (int32_t i = 0; i < RUN_TILE_PIXELS; i++)
      places[(top + i / RUN_TILE_SIDE) * width + left + i % RUN_TILE_SIDE] = tile[i];
  }
  paint_run_images(run);
}

/* Reference#exec_load_sprite_tiles, for one pose drawn from the set: each of its +piece_count+
 * pieces (dx, dy, tile in +pieces+) whose tile is one of the +count+ from +to+ takes tile
 * +at + (tile - to)+ of the table, 32 entries a tile, two places a byte with the left one in the
 * low four bits. The build has checked that both runs are inside their ends. */
void rg_tile_pose_load(int32_t run, const int32_t *pieces, int32_t piece_count, const void *table, int32_t kept,
                       int32_t at, int32_t to, int32_t count) {
  const int32_t *fields = run_fields(run);
  uint8_t *places = places_of(run);
  int32_t width = fields[RG_RUN_WIDTH];
  for (int32_t piece = 0; piece < piece_count; piece++) {
    int32_t dx = pieces[3 * piece], dy = pieces[3 * piece + 1], tile = pieces[3 * piece + 2];
    if (tile < to || tile >= to + count) continue;
    int32_t first = (at + tile - to) * (RUN_TILE_PIXELS / 2);
    for (int32_t byte_at = 0; byte_at < RUN_TILE_PIXELS / 2; byte_at++) {
      int32_t byte = rg_table_entry(table, kept, first + byte_at) & 0xFF;
      int32_t row = byte_at / (RUN_TILE_SIDE / 2), col = (byte_at % (RUN_TILE_SIDE / 2)) * 2;
      places[(dy + row) * width + dx + col] = (uint8_t)(byte & 0x0F);
      places[(dy + row) * width + dx + col + 1] = (uint8_t)(byte >> 4);
    }
  }
  paint_run_images(run);
}

/* Reference#blit_image: a see-through pixel is skipped, and each other one goes on as stored. */
static void blit_image(int32_t image, int32_t x, int32_t y) {
  picture art = picture_of(image);
  for (int32_t row = 0; row < art.height; row++)
    for (int32_t col = 0; col < art.width; col++) {
      int32_t color = art.pixels[row * art.width + col];
      if (color != RG_NOT_DRAWN) set_pixel((int64_t)x + col, (int64_t)y + row, color);
    }
}

static FEATURE_ONLY int32_t rebuilt_whole(void) { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* Reference#exec_blit */
void rg_screen_blit(int32_t image, int32_t x, int32_t y) { blit_image(image, x, y); }

/* Reference#exec_blit_pose: a number outside the set draws nothing. */
void rg_screen_blit_pose(const int32_t *poses, int32_t count, int32_t pose, int32_t x, int32_t y) {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

/* Reference#exec_draw_column_at: one column of a picture, stretched to +height+ rows. The walk
 * goes DOWN THE SCREEN and asks which row of the picture belongs at each screen row, the step
 * held in 65536ths of a picture row and cut off at each step — the console's own rule, so every
 * pixel lands where the other backends put it. Only the rows on the screen are walked. */
void rg_screen_column(int32_t image, int32_t slice, int32_t x, int32_t top, int32_t height, int32_t width) {
  if (height <= 0) return;
  picture art = picture_of(image);
  int64_t column = clamp32(slice, 0, art.width - 1);
  int64_t step = ((int64_t)art.height << 16) / height;
  int64_t first = top < 0 ? -(int64_t)top : 0;
  int64_t past = (int64_t)RG_SCREEN_HEIGHT - top < height ? (int64_t)RG_SCREEN_HEIGHT - top : height;
  for (int64_t row = first; row < past; row++) {
    int64_t source = clamp32((row * step) >> 16, 0, art.height - 1);
    int32_t color = art.pixels[source * art.width + column];
    if (color == RG_NOT_DRAWN) continue;
    for (int32_t across = 0; across < width; across++) set_pixel((int64_t)x + across, top + row, color);
  }
}

/* Reference::FaceEdge: one edge of a face, from its upper end down, as the fill walks it. The
 * numbers are x, u, v, w and shade, each where the edge crosses its first row, then each one's step. */
typedef struct { int32_t first_row, past_row, at[5], step[5]; } face_edge;

/* Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or 0 when
 * it crosses no row's middle. */
static int face_edge_of(const int32_t *top, const int32_t *bottom, face_edge *edge) {
  int32_t first_row = rg_shr(rg_add(top[1], 7), 4);
  int32_t past_row = rg_shr(rg_add(bottom[1], 7), 4);
  if (first_row >= past_row) return 0;
  int32_t along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]));
  int32_t into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4);
  int32_t parts[5] = {rg_shl(rg_sub(bottom[0], top[0]), 12), rg_sub(bottom[2], top[2]), rg_sub(bottom[3], top[3]),
                      rg_sub(bottom[4], top[4]), rg_sub(bottom[5], top[5])};
  int32_t starts[5] = {rg_shl(top[0], 12), top[2], top[3], top[4], top[5]};
  edge->first_row = first_row;
  edge->past_row = past_row;
  for (int part = 0; part < 5; part++) {
    edge->at[part] = rg_add(starts[part], rg_mul_fix(parts[part], into, 24));
    edge->step[part] = rg_mul_fix(parts[part], along_row, 24);
  }
  return 1;
}

/* IR::Reciprocals: 2**40 over each number of eleven bits with the top one set. */
static int32_t face_reciprocals[1024];

/* IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26. */
static int32_t face_distance(int32_t w) {
  if (face_reciprocals[0] == 0) {
    for (int32_t leading = 0; leading < 1024; leading++) face_reciprocals[leading] = (int32_t)((1LL << 40) / (1024 + leading));
  }
  if (w < 4096) w = 4096;
  int moved = 0;
  while ((w >> moved) >= 2048) moved++;
  return face_reciprocals[(w >> moved) - 1024] >> (moved - 2);
}

/* Reference#place_in_perspective: u and v exactly +along+ pixels into a row from +from+ (x, u/z,
 * v/z, 1/z), whose numbers step +steps+ a pixel. */
static void face_place_in_perspective(const int32_t *from, const int32_t *steps, int32_t along, int32_t *place) {
  int32_t over_u = rg_add(from[1], rg_mul(steps[0], along));
  int32_t over_v = rg_add(from[2], rg_mul(steps[1], along));
  int32_t distance = face_distance(rg_add(from[3], rg_mul(steps[2], along)));
  place[0] = rg_mul_fix(over_u, distance, 14);
  place[1] = rg_mul_fix(over_v, distance, 14);
}

/* Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w), in
 * perspective every +spans+ pixels (none when nought). */
/* Reference::Shade's places: where each colour stands in a shading's list of colours, or -1 for a
 * colour not in it. Worked out again only when the shading drawn with changes. */
static const int32_t *shading_placed = NULL;
static int16_t shading_places[32768];

static int32_t shading_place_of(const int32_t *shading, int32_t color) {
  int32_t colors = shading[1];
  if (color < 0 || color >= 32768) {
    for (int32_t place = 0; place < colors; place++)
      if (shading[2 + place] == color) return place;
    return -1;
  }
  if (shading_placed != shading) {
    memset(shading_places, 0xFF, sizeof shading_places);
    for (int32_t place = colors - 1; place >= 0; place--) {
      int32_t listed = shading[2 + place];
      if (listed >= 0 && listed < 32768) shading_places[listed] = (int16_t)place;
    }
    shading_placed = shading;
  }
  return shading_places[color];
}

/* Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
 * +shade+ (its level in the top sixteen bits). */
static int32_t shaded_place(const int32_t *shading, int32_t place, int32_t shade) {
  int32_t colors = shading[1];
  int32_t level = rg_shr(shade, 16);
  return shading[2 + shading[2 + colors + level * colors + place]];
}

/* Reference::Shade#color_at: the colour +color+ becomes at +shade+. A colour not in the shading's
 * list stays as it is. */
static int32_t shaded_color(const int32_t *shading, int32_t color, int32_t shade) {
  int32_t place = shading_place_of(shading, color);
  if (place < 0) return color;
  return shaded_place(shading, place, shade);
}

/* +numbers+ is, for a picture given as numbers into the shading's colours, those numbers as a
 * picture of the same size (Native::Picture#shading_array); its pixels is NULL for any other. */
static void face_row(int32_t row, int32_t *from, int32_t *to, int32_t left, int32_t right, picture art,
                     picture numbers, int32_t spans, const int32_t *shading) {
  int32_t start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16);
  int32_t stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16);
  int32_t count = rg_sub(stop, start);
  if (count <= 0) return;
  if (shading) {
    /* Reference::Shade#held_row_end */
    from[4] = clamp32(from[4], 0, rg_shl(shading[0], 16) - 1);
    to[4] = clamp32(to[4], 0, rg_shl(shading[0], 16) - 1);
  }
  int32_t steps[4];
  for (int part = 0; part < 4; part++) steps[part] = rg_div(rg_sub(to[part + 1], from[part + 1]), count);
  int32_t first = start > left ? start : left;
  int32_t past = stop < right ? stop : right;
  int32_t near_at = -1, near[2], far[2];
  for (int32_t x = first; x < past; x++) {
    int32_t along = rg_sub(x, start);
    int32_t u, v;
    if (spans == 0) {
      u = rg_add(from[1], rg_mul(steps[0], along));
      v = rg_add(from[2], rg_mul(steps[1], along));
    } else {
      /* Reference#place_between: exact at the multiple of +spans+ before and the next, or the end */
      int32_t near_along = (along / spans) * spans;
      int32_t far_along = near_along + spans < count ? near_along + spans : count;
      if (near_along != near_at) {
        face_place_in_perspective(from, steps, near_along, near);
        face_place_in_perspective(from, steps, far_along, far);
        near_at = near_along;
      }
      u = rg_add(near[0], rg_mul(rg_div(rg_sub(far[0], near[0]), far_along - near_along), along - near_along));
      v = rg_add(near[1], rg_mul(rg_div(rg_sub(far[1], near[1]), far_along - near_along), along - near_along));
    }
    int32_t across = rg_and(rg_shr(u, 16), art.width - 1);
    int32_t down = rg_and(rg_shr(v, 16), art.height - 1);
    int32_t color = art.pixels[down * art.width + across];
    if (color == RG_NOT_DRAWN) continue;
    if (shading) {
      int32_t shade = rg_add(from[4], rg_mul(steps[3], along));
      color = numbers.pixels ? shaded_place(shading, numbers.pixels[down * art.width + across], shade)
                             : shaded_color(shading, color, shade);
    }
    set_pixel(x, row, color);
  }
}

/* The most corners a face has (Nodes::FillFace::MOST_CORNERS). */
enum { FACE_MOST_CORNERS = 8 };

/* Reference#exec_fill_face: one face already on the screen, filled with its picture. The corners
 * come six numbers each (x and y in sixteenths of a pixel, u and v in picture pixels with sixteen
 * fraction bits, one over the distance with 26, and the light, 0 to 0xFFFF), and nothing outside
 * left, top, right and bottom is drawn. A +shading+ of [0] draws the picture as it is; any other
 * is its levels, its colours and each level's places (Native::Picture#shading_array), and every
 * pixel is drawn in the colour its blended light's level gives. The picture's number is held to the ends of the list of pictures, and the count
 * to FACE_MOST_CORNERS. In perspective (+spans+ not nought) u and v become u and v over the
 * distance (Reference::FaceEdges.in_perspective) before the edges are walked. */
void rg_screen_face(const int32_t *pictures, int32_t picture_count, int32_t which, const rg_list *corner_list,
                    int32_t corner_count, int32_t left, int32_t top, int32_t right, int32_t bottom, int32_t spans,
                    const int32_t *shading) {
  if (corner_count > FACE_MOST_CORNERS) corner_count = FACE_MOST_CORNERS;
  if (corner_count < 3) return;
  if (shading[0] == 0) shading = NULL;
  int32_t corners[FACE_MOST_CORNERS][6];
  for (int32_t k = 0; k < corner_count; k++) {
    for (int32_t field = 0; field < 6; field++) corners[k][field] = rg_list_get(corner_list, k * 6 + field);
    /* Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels */
    if (shading) corners[k][5] = rg_mul(clamp32(corners[k][5], 0, 0xFFFF), shading[0]);
    if (spans != 0) {
      corners[k][2] = rg_mul_fix(corners[k][2], corners[k][4], 28);
      corners[k][3] = rg_mul_fix(corners[k][3], corners[k][4], 28);
    }
  }
  int32_t image = pictures[clamp32(which, 0, picture_count - 1)];
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  face_edge edges[FACE_MOST_CORNERS];
  int count = 0;
  for (int32_t k = 0; k < corner_count; k++) {
    const int32_t *a = corners[k], *b = corners[(k + 1) % corner_count];
    if (a[1] == b[1]) continue;
    if (a[1] < b[1] ? face_edge_of(a, b, &edges[count]) : face_edge_of(b, a, &edges[count])) count++;
  }
  if (count == 0) return;
  int32_t first = INT32_MAX, past = INT32_MIN;
  for (int e = 0; e < count; e++) {
    if (edges[e].first_row < first) first = edges[e].first_row;
    if (edges[e].past_row > past) past = edges[e].past_row;
  }
  if (first < top) first = top;
  if (past > bottom) past = bottom;
  picture art = picture_of(image);
  /* After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
   * into the shading's colours, or -1 for a picture of colours. */
  picture numbers = {NULL, 0, 0};
  if (shading) {
    int32_t numbered = shading[2 + shading[1] + shading[0] * shading[1] + clamp32(which, 0, picture_count - 1)];
    if (numbered >= 0) numbers = picture_of(numbered);
  }
  for (int32_t row = first; row < past; row++) {
    int32_t from[5] = {INT32_MAX, 0, 0, 0, 0}, to[5] = {INT32_MIN, 0, 0, 0, 0};
    int crossing = 0;
    for (int e = 0; e < count; e++) {
      const face_edge *edge = &edges[e];
      if (row < edge->first_row || row >= edge->past_row) continue;
      int32_t rows = rg_sub(row, edge->first_row);
      int32_t at[5];
      for (int part = 0; part < 5; part++) at[part] = rg_add(edge->at[part], rg_mul(edge->step[part], rows));
      crossing++;
      /* the leftmost is the first of the leftmost, the rightmost the last of the rightmost */
      if (at[0] < from[0]) memcpy(from, at, sizeof at);
      if (at[0] >= to[0]) memcpy(to, at, sizeof at);
    }
    if (crossing >= 2) face_row(row, from, to, left, right, art, numbers, spans, shading);
  }
}

/* Reference#sprites: what the game last put on screen, which stays as it was put until the game next
 * sets its sprites. The headless runners read it for every game, so these stay here, and answer
 * through the hooks: none for a game with no sprites. */
int32_t rg_screen_drawn_count(void) { return rg_hook_drawn_count(); }

rg_drawn_sprite rg_screen_drawn_sprite(int32_t place) { return rg_hook_drawn_sprite(place); }

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

/* The fade half of Reference#set_blend_for, for the thing about to be painted: what is painted from
 * here on goes through the colour table a placed fade in force asks for it (rg_hook_paint_fade_for),
 * or as drawn where there is none. +fade_place+ is how far forward the thing's layer is
 * (RG_BG_FADE_PLACE, rg_game_sprite_fade_places), or RG_NO_LAYER for a thing every placed fade
 * reaches and for the backdrop, which is behind everything. */
static void fade_unless_left_as_drawn(int32_t fade_place) { paint_fade = rg_hook_paint_fade_for(fade_place); }

static void fade_nothing(void) { paint_fade = NULL; }

/* Back to front: the backdrop, then each level's scenery and sprites (rg_hook_paint_level, scenery
 * first), with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending). */
static void repaint_view(void) {
  repaints_painted++;
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(backdrop);
  rg_hook_repaint_began();
  for (int32_t level = 0, levels = rg_game_picture_sizes[RG_SIZE_DEPTHS]; level < levels; level++) {
    rg_hook_paint_level(level);
  }
  rg_hook_repaint_ending();
  mix_nothing();
  fade_nothing();
  picture_touched = 0;
}

/* Reference#paint_owed_repaint */
void rg_screen_paint_owed_rebuild(void) {
  int32_t skipped_and_touched = rebuild_skipped && picture_touched;
  rebuild_skipped = 0;
  if (owed || skipped_and_touched) {
    owed = 0;
    repaint_view();
    forget_kept_shares();
  }
  rg_hook_rebuild_checked();
}

/* --- screens and scenes --- */

void rg_screen_hold(int32_t value) { held = value; }

/* Whether the end of a pass is placing the frame's writes (Reference @placing_at_pass_end): set by
 * every game on a console that places them there, read by what a write placed then leaves alone
 * (a background that pass put up still shows from its corner). */
static int32_t placing_at_pass_end;

void rg_screen_placing_at_pass_end(int32_t on) { placing_at_pass_end = on; }
void rg_screen_frame_started(void) {
  held = 0;
  frames_begun = 1;
}

/* The top of Reference#advance_frame. A frame boundary is the one safe moment to trade the two
 * pages of a tear-free screen, so the page just drawn is shown and the game is handed the other —
 * before anything can stop the run there, so a run that stops on a boundary stops with the frame
 * it finished on screen. */
void rg_screen_frame_ended(void) {
  rg_hook_frame_ended();
  if (pixels == viewed) return;
  rg_screen_paint_owed_rebuild();
  uint16_t *finished = pixels;
  pixels = viewed;
  viewed = finished;
  target = pixels;
  picture_touched = 1; /* the page handed over was built before the one just shown */
  /* Reference#advance_frame: sprites over the picture are placed with the page published. */
  rg_game_sprites_over_picture();
}

/* Reference#show_backdrop: the colour wherever nothing is drawn becomes +color+, the picture painted
 * again over it where anything is up. A colour below nought leaves it as it is: the backdrop follows
 * a list of colours, and only the list changes it (IR::SceneHandover#backdrop_follows_list?). */
static void show_backdrop(int32_t color) {
  if (color < 0 || color == backdrop) return;
  backdrop = color;
  scenery_kept = 0;
  if (rg_hook_scenery_up()) request_repaint();
  else clear_to(backdrop);
}

/* Reference#exec_screen. Every kind of screen is a display of its own, so any change of kind
 * wipes the picture and takes the scenery down (rg_hook_screen_crossed, which puts up again what
 * every screen drawn from tiles shows, as declared: #put_up_always_up), and returns 1 when it
 * arrives on a screen drawn from tiles. A change between one page and two keeps the same picture
 * and wipes nothing. +new_backdrop+ is the colour shown wherever nothing is drawn from here
 * (IR::SceneHandover#backdrop_of). */
int32_t rg_screen_set(int32_t new_kind, int32_t two_pages, int32_t new_backdrop) {
  int32_t crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    if (new_backdrop >= 0) backdrop = new_backdrop;
    clear_to(backdrop);
    scenery_kept = 0;
  } else {
    show_backdrop(new_backdrop);
  }
  kind = new_kind;
  show_pages(two_pages);
  rg_hook_screen_set(); /* a tint in force is mixed this screen's way (rg_fades_screen_set) */
  if (!crossing) return 0;
  rg_hook_screen_crossed(new_kind);
  return new_kind != RG_BITMAP;
}

/* Reference#cross_to_scene_screen */
int32_t rg_screen_cross_to(int32_t new_kind, int32_t two_pages, int32_t new_backdrop) {
  if (kind >= 0 && kind != new_kind) return rg_screen_set(new_kind, two_pages, new_backdrop);
  show_backdrop(new_backdrop);
  return 0;
}

/* Reference#exec_color_list_holds, for a backdrop that follows the list: its colour in the set the
 * list holds now. */
void rg_screen_show_backdrop(int32_t color) { show_backdrop(color); }

void rg_scene_enter(int32_t scene) { current_scene = scene; }

/* Whether the last scene to take over took any scenery down (Reference#take_down_scenery's
 * answer), which rg_scene_redraw_sprites asks. */
static int32_t scenery_taken_down;

/* The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes
 * down (rg_hook_scene_take_down). */
void rg_scene_take_down(int32_t brings_scenery) { scenery_taken_down = rg_hook_scene_take_down(brings_scenery); }

/* Reference#redraw_sprites_over_arrived_scenery: the sprites of this frame were drawn as it began,
 * the leaving scene's among them, and the scenery a scene put up after them covered them. The
 * display draws sprites over whatever scenery is up, so the picture is built again from the
 * scenery and the sprites kept when they were drawn. A painted screen is left alone. The same
 * for a scene that brings none but took the last one's down, which wiped those sprites too. */
void rg_scene_redraw_sprites(int32_t brings_scenery) {
  if (!brings_scenery && !scenery_taken_down) return;
  if (painted_screen() || !rg_hook_any_sprite_kept()) return;
  request_repaint();
}

/* --- reading it back --- */

int32_t rg_screen_two_pages(void) { return pixels != viewed; }

int32_t rg_screen_repaints_painted(void) { return repaints_painted; }

/* Framebuffer#to_a: the page a viewer is looking at as it is STORED, with no window moved over
 * it and no fade or tint mixed in. */
const uint16_t *rg_screen_stored(void) {
  rg_screen_paint_owed_rebuild();
  return viewed;
}

/* rg_screen_shown with nothing over the picture: each row is the stored row the window sits over,
 * moved as one piece, and off the edge of the picture the backdrop shows, which is nought here
 * (a colour no filter changes). Where the window is moved sideways only the part of the
 * row that stays on the picture is copied, and the rest is cleared. */
static void shown_plain(void) {
  int64_t first = camera_x < 0 ? -(int64_t)camera_x : 0; /* the first screen column on the picture */
  int64_t past = camera_x > 0 ? RG_SCREEN_WIDTH - (int64_t)camera_x : RG_SCREEN_WIDTH; /* the one after the last */
  if (first > RG_SCREEN_WIDTH) first = RG_SCREEN_WIDTH;
  if (past < first) past = first;
  for (int32_t y = 0; y < RG_SCREEN_HEIGHT; y++) {
    uint16_t *row = &shown[y * RG_SCREEN_WIDTH];
    int64_t from_y = (int64_t)y + camera_y;
    if (from_y < 0 || from_y >= RG_SCREEN_HEIGHT) {
      memset(row, 0, RG_SCREEN_WIDTH * sizeof row[0]);
      continue;
    }
    const uint16_t *stored = &viewed[from_y * RG_SCREEN_WIDTH];
    memset(row, 0, (size_t)first * sizeof row[0]);
    if (past > first) memcpy(row + first, stored + first + camera_x, (size_t)(past - first) * sizeof row[0]);
    memset(row + past, 0, (size_t)(RG_SCREEN_WIDTH - past) * sizeof row[0]);
  }
}

/* Framebuffer#displayed: the picture as a console that keeps fewer than five bits of a channel (the
 * Genesis keeps three) shows it, each channel's top bits repeated to widen it back to five. Rounded
 * here, as the picture is read, so a fade or a mix still works on the colour the game named. */
static void keep_console_colors(void) {
  if (RG_COLOR_BITS >= 5) return;
  int32_t lost = 5 - RG_COLOR_BITS, kept_mask = (1 << RG_COLOR_BITS) - 1;
  for (int32_t at = 0; at < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; at++) {
    int32_t color = shown[at], kept = 0;
    for (int32_t channel = 0; channel <= 10; channel += 5) {
      int32_t level = (color >> (channel + lost)) & kept_mask;
      kept |= ((level << lost) | (level >> (RG_COLOR_BITS - lost))) << channel;
    }
    shown[at] = (uint16_t)kept;
  }
}

/* Does the filter's row say it changes the pixel at column +x+? The row is [from, to, inverted]: a
 * pixel is changed when inverted XOR from <= x < to. */
static int32_t filter_row_covers(const int32_t *row, int32_t x) { return row[2] ^ (x >= row[0] && x < row[1]); }

/* Framebuffer#shown and #pixel: the page a viewer is looking at, read through the window — off
 * the edge of the picture the backdrop shows — with the fade or tint in force mixed in, read from
 * where a feature says each pixel is read from (rg_hook_shown_columns, rg_hook_shown_row), with the
 * layer a feature shows in front of the picture laid over it (rg_hook_front_layer, asked once a
 * read), and darkened outside a light's span. A switched-off display shows plain white.
 *
 * The fade or tint and the light are filters (shown_filter) a feature hands over once a read
 * (rg_hook_fade_filter, rg_hook_dim_filter), and the loop below only reads the tables they hold.
 * A pixel is read as the colour stored (or in front, or nought off the picture), then through the
 * fade's table where that reaches it, then through the light's where that does, and a held display
 * shows white instead.
 *
 * With the display on and no fade, tint or light darkening any of it and no feature reading it
 * its own way (rg_hook_shown_plain), none of that touches a colour, and every row is copied
 * (shown_plain), which is most frames of most games. Anything else is worked out a pixel at a time. */
const uint16_t *rg_screen_shown(void) {
  rg_screen_paint_owed_rebuild();
  const uint16_t *front = rg_hook_front_layer();
  const shown_filter *fade = rg_hook_fade_filter();
  const shown_filter *dim = rg_hook_dim_filter();
  if (!held && !fade && !dim && rg_hook_shown_plain()) {
    shown_plain();
    if (front)
      for (int32_t at = 0; at < CELLS; at++)
        if (front[at] != RG_NOTHING_IN_FRONT) shown[at] = front[at];
    keep_console_colors();
    return shown;
  }
  const int64_t *columns = rg_hook_shown_columns();
  for (int32_t y = 0; y < RG_SCREEN_HEIGHT; y++) {
    int64_t from_y = rg_hook_shown_row(y) + camera_y;
    const int32_t *fade_row = fade && !fade->everywhere ? fade->rows[y] : NULL;
    const int32_t *dim_row = dim && !dim->everywhere ? dim->rows[y] : NULL;
    for (int32_t x = 0; x < RG_SCREEN_WIDTH; x++) {
      int32_t fade_here = fade && (!fade_row || filter_row_covers(fade_row, x));
      uint16_t in_front = front ? front[y * RG_SCREEN_WIDTH + x] : (uint16_t)RG_NOTHING_IN_FRONT;
      uint16_t color;
      if (in_front != RG_NOTHING_IN_FRONT) {
        color = fade_here ? fade->table[in_front] : in_front; /* Framebuffer#pixel: a sprite over the picture is not in blocks */
      } else {
        int64_t from_x = (columns ? columns[x] : x) + camera_x;
        int64_t at = from_y * RG_SCREEN_WIDTH + from_x;
        if (!on_screen(from_x, from_y)) {
          color = fade_here ? fade->table[0] : 0;
        } else if (fade && fade->remix && picture_mixes.is_mixed[at]) {
          /* Framebuffer#shown_color: a mixed cell is mixed again from its two sides, each through the table */
          color = mixed_with_under(fade->table[picture_mixes.tops[at]], fade->table[picture_mixes.unders[at]], mixed_cells_by);
        } else {
          color = fade_here ? fade->table[viewed[at]] : viewed[at];
        }
      }
      if (dim && (!dim_row || filter_row_covers(dim_row, x))) color = dim->table[color];
      shown[y * RG_SCREEN_WIDTH + x] = held ? (uint16_t)0x7FFF : color;
    }
  }
  keep_console_colors();
  return shown;
}

/* The game's runtime features and the hooks they take, written by the build beside game.c
 * (RuntimeFeatures#c_text); then what a hook none of them takes does. A file read on its own, by
 * the editor's checker, has no game and so no features. */
#if __has_include("rg_runtime_features.h")
#include "rg_runtime_features.h"
#endif
#include "rg_screen_hook_defaults.h"
