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

/* The size of the blocks scenery and sprites are painted in (Reference @block): each puts itself
 * into blocks of it (rg_tiled.c's paint_scenery_in_blocks, Reference#paint_scenery_in_blocks;
 * rg_sprites.c's paint_kept_sprite, Reference#paint_snapshot_object).
 * Must be inline, as its hook is: a game that pixelates a painted screen has nothing to ask it. */
static inline int32_t rg_pixelation_block_size(void) { return block; }

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

/* rg_hook_visit_state: the two sizes (Computer::StateFields "pixelation"). */
static void rg_pixelation_visit_state(void) {
  int64_t numbers[] = {block, read_block};
  rg_state_numbers("pixelation", numbers, 2);
  if (numbers[0] < 1 || numbers[1] < 1)
    rg_state_refuse_damaged("its blocks are smaller than a pixel");
  block = (int32_t)numbers[0], read_block = (int32_t)numbers[1];
}
