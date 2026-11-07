/*
 * THE PICTURE IN FLAT BLOCKS (Reference @block, Reference::SpriteBlocks): `pixelate`, joined into the
 * runtime's script after rg_screen.js for a game that pixelates. rg_pixelation.c says how, rule for
 * rule; this is that file written again, function for function.
 */

let block = 1, read_block = 1;

/* Reference#exec_pixelate */
function rg_screen_pixelate(size) {
  const held_to = clamp_number(size, 1, rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK]);
  if (held_to === block) return;
  block = held_to;
  if (painted_screen()) read_block = block;
  else request_repaint();
}

/* Reference#exec_screen */
function rg_pixelation_screen_set() { read_block = painted_screen() ? block : 1; }

/* The size of the blocks scenery and sprites are painted in (Reference @block): each puts itself
 * into blocks of it (rg_tiled.js's paint_scenery_in_blocks, Reference#paint_scenery_in_blocks;
 * rg_sprites.js's paint_kept_sprite, Reference#paint_snapshot_object). */
function rg_pixelation_block_size() { return block; }

/* --- a painted screen read in blocks (Framebuffer#block_corner) --- */

const shown_columns = new Float64Array(RG_SCREEN_WIDTH);
function rg_pixelation_shown_columns() {
  if (read_block === 1) return null;
  const first = camera_x < 0 ? -camera_x : 0;
  for (let x = 0; x < RG_SCREEN_WIDTH; x++)
    shown_columns[x] = x >= first ? first + Math.trunc((x - first) / read_block) * read_block : x;
  return shown_columns;
}

function rg_pixelation_shown_row(y) { return y - (y % read_block); }
