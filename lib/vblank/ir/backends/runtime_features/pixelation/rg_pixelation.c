/*
 * THE PICTURE IN FLAT BLOCKS (Reference @block, Reference::SpriteBlocks): `pixelate`, and the
 * painting and reading it changes. A runtime feature (backends/runtime_features.rb): this file is
 * included at the end of rg_screen.c, for a game that pixelates, so it reads the screen's own
 * state and painters as if it were written there. A game that never pixelates builds without it.
 */
#include "rg_pixelation.h"

/* How many pixels a block is each way, 1 being the picture as drawn. A picture built from several
 * things is put into blocks a thing at a time, as the view is rebuilt. A screen the game paints is
 * one thing to the display, so it goes into blocks whole as it is read, and +read_block+ is the size
 * it is read in (Framebuffer @block). */
static int32_t block = 1, read_block = 1;

/* Reference#exec_pixelate. Nothing painted so far changes: the size is read as the picture is
 * next built, or as a painted screen is next read, so the picture is owed again only when the
 * size is a different one. */
void rg_screen_pixelate(int32_t size) {
  int32_t held_to = clamp32(size, 1, rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK]);
  if (held_to == block) return;
  block = held_to;
  if (painted_screen()) read_block = block;
  else request_repaint();
}

/* Reference#exec_screen: the size of a block outlasts the screen it was set on, and a screen drawn
 * from tiles is read as it is, being put into blocks a thing at a time instead. */
static void rg_pixelation_screen_set(void) { read_block = painted_screen() ? block : 1; }

/* --- a background in blocks --- */

/* Reference#paint_scenery_in_blocks: ONE BACKGROUND IN BLOCKS, by the display's own rule.
 *
 * The blocks are fixed to the screen, and each shows the color the background has at the block's
 * top left corner, so a background that scrolls slides under a grid that stays where it is. A
 * corner that is see-through leaves the whole block see-through.
 *
 * Down and across are done apart, because a display draws a row at a time. Down: every row of a
 * block is drawn from the map row its top row shows, and still placed by its OWN bend, so a
 * background bent row by row keeps each row's bend and a block of it is a sheared one. Across:
 * each pixel of a row then takes the one at the start of its block in that same row. So the
 * background goes onto the sheet rows first, and is laid on the picture through the blocks, with
 * whatever mix or fade is in force for it applied as it is laid. A background held to a box keeps
 * to the box as it is laid (laying_box).
 *
 * Reference#block_width_across: a background that can turn is left one pixel wide at a size of
 * two, so its rows double and its columns do not. That is the emulator's, kept because the
 * console's picture is checked against it. */
static void paint_scenery_in_blocks(int32_t background) {
  for (int32_t i = 0; i < CELLS; i++) sheet[i] = NOTHING_ON_SHEET;
  onto_sheet = 1;
  rows_tall = block;
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  int32_t wide = background_field(background, RG_BG_CAN_TURN) && block == 2 ? 1 : block;
  for (int64_t py = 0, rows = scenery_rows(); py < rows; py++)
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      if (laying_box && (px < laying_box->left || px >= laying_box->right || py < laying_box->top ||
                         py >= laying_box->bottom))
        continue;
      int32_t color = sheet[py * RG_SCREEN_WIDTH + px - px % wide];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, (uint16_t)color);
    }
}

/* Reference#paint_scenery: a background the game has not left as drawn is painted in blocks while
 * the blocks are bigger than a pixel. Answers whether it was. */
static int32_t rg_pixelation_paint_scenery(int32_t background) {
  if (block == 1 || !background_field(background, RG_BG_IN_BLOCKS)) return 0;
  paint_scenery_in_blocks(background);
  return 1;
}

/* --- a sprite in blocks (Reference::SpriteBlocks, which holds the rule and says why) ---
 *
 * The blocks are fixed to the screen, as a background's are. What differs is where a block takes
 * its color from, because a sprite is a small box and a block need not start inside it. */

static int64_t clamp64(int64_t value, int64_t low, int64_t high) { return value < low ? low : (value > high ? high : value); }

/* SpriteBlocks#block_start and #round_up: where the block a column or row is in starts, and the
 * end of the block an edge falls in. */
static int64_t block_start(int64_t at) { return at - floor_mod(at, block); }
static int64_t block_end(int64_t edge) { return -floor_div(-edge, block) * block; }

/* Reference#picture_reader: what a picture shows at a column and row of itself, or RG_NOT_DRAWN
 * where it is see-through and anywhere outside it. */
static int32_t picture_color(picture art, int64_t col, int64_t row) {
  if (col < 0 || col >= art.width || row < 0 || row >= art.height) return RG_NOT_DRAWN;
  return art.pixels[row * art.width + col];
}

/* SpriteBlocks#paint_box: one box of a sprite whose picture's corner is at (x, y), the box's own
 * corner at (left, top) on the screen. A block that starts left of the box or above it shows the
 * box's first column or row; the last block across is drawn whole, past the box's right edge;
 * nothing is drawn past its bottom edge. */
static void paint_box_in_blocks(picture art, int64_t x, int64_t y, int64_t left, int64_t top, int64_t width, int64_t height) {
  int64_t first_row = top > 0 ? top : 0, past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT;
  int64_t first_col = left > 0 ? left : 0, past_col = block_end(left + width);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  for (int64_t py = first_row; py < past_row; py++) {
    int64_t from_y = clamp64(block_start(py), top, top + height - 1);
    for (int64_t px = first_col; px < past_col; px++) {
      int32_t color = picture_color(art, clamp64(block_start(px), left, left + width - 1) - x, from_y - y);
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* SpriteBlocks#paint_upright: a sprite that stands upright, a box at a time, back to front, so
 * where one box's last block runs over the next the one in front wins. The boxes are the ones
 * listed for the picture it shows (rg_game_sprite_boxes). */
static void paint_upright_in_blocks(const placed_object *placed) {
  const int32_t *listed = rg_game_sprite_boxes + rg_game_sprite_blocks[placed->sprite];
  int32_t pictures = *listed++, showing = rg_game_image_pictures[placed->image];
  for (int32_t i = 0; i < pictures; i++) {
    int32_t name = listed[0], boxes = listed[1];
    const int32_t *box = listed + 2;
    listed = box + 4 * boxes;
    if (name != showing) continue;
    picture art = picture_of(placed->image);
    for (int32_t b = boxes - 1; b >= 0; b--)
      paint_box_in_blocks(art, placed->x, placed->y, (int64_t)placed->x + box[4 * b], (int64_t)placed->y + box[4 * b + 1],
                          box[4 * b + 2], box[4 * b + 3]);
    return;
  }
  rg_fault("sprite %d is shown in blocks and has no boxes for the picture it shows", placed->sprite);
}

/* SpriteBlocks#turned_row: the row of its box a turned sprite shows on screen row +py+, which is
 * the row at the top of the block, held to the box's first row when the block began above it. It
 * is worked out as the display counts, in lines that come round, which is where the odd case
 * comes from: a box that ends past the last line the display counts reads its last row on every
 * row that shows. */
static int64_t turned_row(int64_t py, int64_t top, int64_t height) {
  enum { LINES = 256 };
  int64_t first = floor_mod(top, LINES), past = first + height, line = block_start(py);
  if (line < first && first < RG_SCREEN_HEIGHT) line = first;
  if (line >= past % LINES) line = past - 1;
  return floor_mod(line - first, LINES);
}

/* SpriteBlocks#paint_turned, and the walk back to the picture Reference#paint_object_in_blocks
 * hands it: a sprite that turns or resizes, drawn in a box twice its picture's size about the
 * picture's middle. A block that starts left of the box shows what the turned picture would show
 * ONE COLUMN before the box begins, which is nearly always nothing; one that starts above it
 * shows the box's first row; and the last block across is drawn whole. */
static void paint_turned_in_blocks(const placed_object *placed) {
  picture art = picture_of(placed->image);
  int64_t width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix((int32_t)floor_mod(placed->angle, 360), placed->size, &turn_cos, &turn_sin);
  int64_t left = (int64_t)placed->x - width / 2, top = (int64_t)placed->y - height / 2;
  int64_t first_col = left > 0 ? left : 0, past_col = block_end(left + width * 2);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  if (!turned_box_on_screen(top, width, height, placed->resizes)) return;
  for (int64_t iy = 0; iy < height * 2; iy++) {
    int64_t py = turned_box_line(top, iy);
    if (py < 0) continue;
    int64_t dy = turned_row(py, top, height * 2) - height;
    for (int64_t px = first_col; px < past_col; px++) {
      int64_t start = block_start(px);
      int64_t dx = (start >= left ? start : left - 1) - left - width;
      int32_t color = picture_color(art, floor_div(turn_cos * dx + turn_sin * dy, one_th) + width / 2,
                                    floor_div(-turn_sin * dx + turn_cos * dy, one_th) + height / 2);
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* Reference#paint_snapshot_object: one of the sprites kept for a rebuild is drawn in blocks while
 * the picture is shown in them, unless the game leaves it as drawn. Answers whether it was. */
static int32_t rg_pixelation_paint_kept_sprite(const placed_object *placed) {
  if (block == 1 || rg_game_sprite_blocks[placed->sprite] == RG_NOT_IN_BLOCKS) return 0;
  if (placed->turned) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
  return 1;
}

/* --- a painted screen read in blocks --- */

/* Framebuffer#shown: a painted screen in blocks of one is read as it is. */
static int32_t rg_pixelation_shown_plain(void) { return read_block == 1; }

/* Framebuffer#block_corner: the screen column whose color each column shows while a painted screen
 * is read in blocks, which is the first of its block. Across, the blocks are fixed to the screen
 * while the picture covers the row from its first column. When the window has been moved off the
 * picture's left edge the first block of a row starts where the picture does, and the rest count
 * from there: a display starts a block at the first pixel it finds something to show. Worked out
 * once for every column each time the picture is read. */
static int64_t shown_columns[RG_SCREEN_WIDTH];
static const int64_t *rg_pixelation_shown_columns(void) {
  if (read_block == 1) return NULL;
  int64_t first = camera_x < 0 ? -(int64_t)camera_x : 0;
  for (int64_t x = 0; x < RG_SCREEN_WIDTH; x++)
    shown_columns[x] = x >= first ? first + ((x - first) / read_block) * read_block : x;
  return shown_columns;
}

/* Framebuffer#pixel: down, every row of a block shows the block's top row. */
static int64_t rg_pixelation_shown_row(int64_t y) { return y - y % read_block; }
