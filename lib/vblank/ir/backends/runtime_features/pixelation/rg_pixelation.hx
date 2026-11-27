/*
 * The picture in flat blocks (Reference @block, Reference::SpriteBlocks): `pixelate`. A port of the JavaScript runtime's
 * rg_pixelation.js, function for function (rg_pixelation.c says how, rule for rule). A runtime feature
 * (backends/runtime_features.rb), joined into the runtime after rg_screen.hx for a game that pixelates.
 */

static var block:Int = 1;
static var read_block:Int = 1;

/* Reference#exec_pixelate */
static function rg_screen_pixelate(size:Int):Void {
  var held_to = clamp_number(size, 1, rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK]);
  if (held_to == block) return;
  block = held_to;
  if (painted_screen()) read_block = block;
  else request_repaint();
}

/* Reference#exec_screen */
static function rg_pixelation_screen_set():Void { read_block = painted_screen() ? block : 1; }

/* The size of the blocks scenery and sprites are painted in (Reference @block): each puts itself into blocks of it
 * (rg_tiled.hx's paint_scenery_in_blocks, Reference#paint_scenery_in_blocks; rg_sprites.hx's paint_kept_sprite,
 * Reference#paint_snapshot_object). */
static function rg_pixelation_block_size():Int { return block; }

/* --- a painted screen read in blocks (Framebuffer#block_corner) --- */

static var blocked_columns:Vector<Int> = new Vector<Int>(RG_SCREEN_WIDTH);
static function rg_pixelation_shown_columns():Vector<Int> {
  if (read_block == 1) return null;
  var first = camera_x < 0 ? -camera_x : 0;
  for (x in 0...RG_SCREEN_WIDTH) blocked_columns[x] = x >= first ? first + Std.int((x - first) / read_block) * read_block : x;
  return blocked_columns;
}

static function rg_pixelation_shown_row(y:Int):Int { return y - (y % read_block); }

/* rg_hook_visit_state: the two sizes (Computer::StateFields "pixelation"). */
static function rg_pixelation_visit_state():Void {
  var numbers:Array<Int> = [block, read_block];
  rg_state_numbers("pixelation", numbers);
  if (numbers[0] < 1 || numbers[1] < 1) rg_state_refuse_damaged("its blocks are smaller than a pixel");
  block = numbers[0];
  read_block = numbers[1];
}
