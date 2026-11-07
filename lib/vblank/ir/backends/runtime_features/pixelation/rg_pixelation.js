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

/* Reference#paint_scenery_in_blocks */
function paint_scenery_in_blocks(background) {
  sheet.fill(NOTHING_ON_SHEET);
  onto_sheet = 1;
  rows_tall = block;
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  const wide = background_field(background, RG_BG_CAN_TURN) && block === 2 ? 1 : block;
  for (let py = 0, rows = scenery_rows(); py < rows; py++) {
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      if (laying_box && (px < laying_box.left || px >= laying_box.right || py < laying_box.top ||
                         py >= laying_box.bottom)) continue;
      const color = sheet[py * RG_SCREEN_WIDTH + px - (px % wide)];
      if (color !== NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_scenery */
function rg_pixelation_paint_scenery(background) {
  if (block === 1 || !background_field(background, RG_BG_IN_BLOCKS)) return false;
  paint_scenery_in_blocks(background);
  return true;
}

/* --- a sprite in blocks (Reference::SpriteBlocks) --- */

function block_start(at) { return at - floor_mod(at, block); }
function block_end(edge) { return -floor_div(-edge, block) * block; }

function picture_color(art, col, row) {
  if (col < 0 || col >= art.width || row < 0 || row >= art.height) return RG_NOT_DRAWN;
  return art.pixels[art.start + row * art.width + col];
}

/* SpriteBlocks#paint_box */
function paint_box_in_blocks(art, x, y, left, top, width, height) {
  const first_row = top > 0 ? top : 0, past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT;
  const first_col = left > 0 ? left : 0;
  let past_col = block_end(left + width);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  for (let py = first_row; py < past_row; py++) {
    const from_y = clamp_number(block_start(py), top, top + height - 1);
    for (let px = first_col; px < past_col; px++) {
      const color = picture_color(art, clamp_number(block_start(px), left, left + width - 1) - x, from_y - y);
      if (color !== RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* SpriteBlocks#paint_upright */
function paint_upright_in_blocks(placed) {
  let listed = rg_game_sprite_blocks[placed.sprite];
  const pictures = rg_game_sprite_boxes[listed++], showing_picture = rg_game_image_pictures[placed.image];
  for (let i = 0; i < pictures; i++) {
    const name = rg_game_sprite_boxes[listed], boxes = rg_game_sprite_boxes[listed + 1];
    const box = listed + 2;
    listed = box + 4 * boxes;
    if (name !== showing_picture) continue;
    const art = picture_of(placed.image);
    for (let b = boxes - 1; b >= 0; b--) {
      paint_box_in_blocks(art, placed.x, placed.y, placed.x + rg_game_sprite_boxes[box + 4 * b],
        placed.y + rg_game_sprite_boxes[box + 4 * b + 1], rg_game_sprite_boxes[box + 4 * b + 2],
        rg_game_sprite_boxes[box + 4 * b + 3]);
    }
    return;
  }
  rg_fault(`sprite ${placed.sprite} is shown in blocks and has no boxes for the picture it shows`);
}

/* SpriteBlocks#turned_row */
function turned_row(py, top, height) {
  const LINES = 256;
  const first = floor_mod(top, LINES), past = first + height;
  let line = block_start(py);
  if (line < first && first < RG_SCREEN_HEIGHT) line = first;
  if (line >= past % LINES) line = past - 1;
  return floor_mod(line - first, LINES);
}

/* SpriteBlocks#paint_turned */
function paint_turned_in_blocks(placed) {
  const art = picture_of(placed.image);
  const width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(floor_mod(placed.angle, 360), placed.size);
  const left = placed.x - Math.trunc(width / 2), top = placed.y - Math.trunc(height / 2);
  const first_col = left > 0 ? left : 0;
  let past_col = block_end(left + width * 2);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  if (!turned_box_on_screen(top, width, height, placed.resizes)) return;
  for (let iy = 0; iy < height * 2; iy++) {
    const py = turned_box_line(top, iy);
    if (py < 0) continue;
    const dy = turned_row(py, top, height * 2) - height;
    for (let px = first_col; px < past_col; px++) {
      const start = block_start(px);
      const dx = (start >= left ? start : left - 1) - left - width;
      const color = picture_color(art, floor_div(turn_cos * dx + turn_sin * dy, one_th) + Math.trunc(width / 2),
        floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Math.trunc(height / 2));
      if (color !== RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* Reference#paint_snapshot_object */
function rg_pixelation_paint_kept_sprite(placed) {
  if (block === 1 || rg_game_sprite_blocks[placed.sprite] === RG_NOT_IN_BLOCKS) return false;
  if (placed.turned) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
  return true;
}

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
