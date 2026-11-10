/*
 * SPRITES AND THEIR DRAW ORDER (Reference#exec_present_objects and the sprites it keeps): joined into
 * the runtime's script after rg_screen.js for a game that declares a sprite. rg_sprites.c says how,
 * rule for rule; this is that file written again, function for function. It reads the screen's own
 * state and painters as if it were written there.
 */

/* The sprites on screen this frame: being set (drawing), and as the last rebuild draws them. */
let drawing = [];
let sprite_layer = [];

/* Where each sprite was last drawn straight onto the picture (Reference @obj_prev). */
const last_drawn = [];
for (let i = 0; i < RG_MAX_SPRITES; i++) last_drawn.push({ drawn: 0, x: 0, y: 0 });

/* Sprites over a painted picture (rg_sprites.c's over_picture): one color or RG_NOTHING_IN_FRONT for
 * each place on the screen, in front of the picture, painted as the screen's plain layer
 * (paint_onto_plain_layer) and shown while +over_picture_up+ (rg_sprites_front_layer). */
const over_picture = new Uint16Array(RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT);
let over_picture_up = false;

/* Reference#set_see_through_for, for a sprite */
function mix_as_sprite(sprite) {
  mix_as_layer(rg_game_sprite_see_through[sprite]);
  painting_sprite = 1;
}

/* WHICH ROWS OF THE SCREEN THE BOX OF A TURNED SPRITE IS SHOWN ON (Reference::TurnedBox). */
const TURNED_BOX_LINES = 256;

function turned_box_line(top, row) {
  const line = floor_mod(top + row, TURNED_BOX_LINES);
  return line < RG_SCREEN_HEIGHT ? line : -1;
}

/* Ruby's Integer.sqrt */
function whole_root(value) {
  let root = Math.floor(Math.sqrt(value));
  while (root * root > value) root--;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

function turned_box_on_screen(top, width, height, resizes) {
  let first = 0, past = height * 2;
  if (!resizes) {
    const reach = whole_root(width * width + height * height) + 2;
    first = height - Math.trunc(reach / 2);
    past = first + reach;
  }
  return top + past > 0 && top + first < RG_SCREEN_HEIGHT;
}

/* Reference#blit_image_transformed */
function blit_image_turned(image, x, y, angle, size, resizes) {
  const art = picture_of(image);
  const width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(floor_mod(angle, 360), size);
  const left = x - Math.trunc(width / 2), top = y - Math.trunc(height / 2);
  if (!turned_box_on_screen(top, width, height, resizes)) return;
  for (let iy = 0; iy < height * 2; iy++) {
    const line = turned_box_line(top, iy);
    if (line < 0) continue;
    const dy = iy - height;
    for (let ix = 0; ix < width * 2; ix++) {
      const dx = ix - width;
      const from_x = floor_div(turn_cos * dx + turn_sin * dy, one_th) + Math.trunc(width / 2);
      const from_y = floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Math.trunc(height / 2);
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      const color = art.pixels[art.start + from_y * width + from_x];
      if (color !== RG_NOT_DRAWN) set_pixel(left + ix, line, color);
    }
  }
}

/* --- how many sprites a line of the screen shows (rg_sprites.c's, Backends::SpriteLines) ---
 * rg_game_image_pieces: how tall a piece is, then where each image's pieces start, and there how
 * many, then each one's across and down. RG_SPRITE_PIECES_A_LINE is 0 where every piece is drawn. */
const PIECE_WIDTH = 8;

function pieces_start(image) { return rg_game_image_pieces[1 + image]; }

/* Reference#mark_slices_left_out: each sprite that loses slices to a crowded line keeps them as
 * +cuts+, [line, piece] each. The table lists them front-most first: the deepest level last, and
 * inside a level the one drawn last first. */
function mark_slices_left_out(placed) {
  for (const sprite of placed) sprite.cuts = null;
  if (RG_SPRITE_PIECES_A_LINE === 0 || placed.length === 0) return;
  const order = placed.map((_, at) => at).sort((a, b) => placed[b].level - placed[a].level || b - a);
  const taken = new Int32Array(RG_SCREEN_HEIGHT), tall = rg_game_image_pieces[0];
  for (const at of order) {
    const sprite = placed[at], start = pieces_start(sprite.image), cuts = [];
    for (let piece = 0; piece < rg_game_image_pieces[start]; piece++) {
      const left = sprite.x + rg_game_image_pieces[start + 1 + 2 * piece];
      const top = sprite.y + rg_game_image_pieces[start + 2 + 2 * piece];
      if (left <= -PIECE_WIDTH || left >= RG_SCREEN_WIDTH) continue;
      for (let line = Math.max(top, 0); line < Math.min(top + tall, RG_SCREEN_HEIGHT); line++) {
        if (taken[line]++ >= RG_SPRITE_PIECES_A_LINE) cuts.push([line, piece]);
      }
    }
    if (cuts.length > 0) sprite.cuts = cuts;
  }
}

/* SpriteLines.left_out_at?: left out where a piece left out of the line covers it and no piece
 * drawn there does. */
function left_out_at(placed, col, row, line) {
  const start = pieces_start(placed.image), tall = rg_game_image_pieces[0];
  let covered = false;
  for (let piece = 0; piece < rg_game_image_pieces[start]; piece++) {
    const across = rg_game_image_pieces[start + 1 + 2 * piece], down = rg_game_image_pieces[start + 2 + 2 * piece];
    if (col < across || col >= across + PIECE_WIDTH || row < down || row >= down + tall) continue;
    if (!placed.cuts.some(([l, p]) => l === line && p === piece)) return false;
    covered = true;
  }
  return covered;
}

/* Reference#blit_image with a sprite's slices left out. */
function blit_with_slices_left_out(placed) {
  const art = picture_of(placed.image);
  for (let row = 0; row < art.height; row++) {
    for (let col = 0; col < art.width; col++) {
      const color = art.pixels[art.start + row * art.width + col];
      if (color !== RG_NOT_DRAWN && !left_out_at(placed, col, row, placed.y + row)) set_pixel(placed.x + col, placed.y + row, color);
    }
  }
}

/* Reference#draw_object and #paint_snapshot_object */
function draw_placed(placed) {
  if (placed.turned) blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes);
  else if (placed.cuts) blit_with_slices_left_out(placed);
  else blit_image(placed.image, placed.x, placed.y);
}

/* Reference#scene_framebuffer: the backdrop, and every background showing stamped over it
 * (rg_hook_stamp_scenery). */
function keep_scenery() {
  if (scenery_kept) return;
  const outer = area;
  area = { in_force: 0, left: 0, top: 0, right: 0, bottom: 0 };
  target = scenery;
  clear_to(backdrop);
  rg_hook_stamp_scenery();
  target = pixels;
  area = outer;
  scenery_kept = 1;
}

/* The start of Reference#exec_present_objects */
function rg_objects_begin() {
  drawing = [];
  if (!rebuilt_whole()) keep_scenery();
}

function fault_unless_sprite(sprite) {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault(`sprite number ${sprite} is not one of the ${RG_MAX_SPRITES} there is room for`);
}

/* Framebuffer#put_back_cell */
function put_back_cell(x, y) {
  const at = y * RG_SCREEN_WIDTH + x;
  set_pixel(x, y, scenery[at]);
  const kept = mixes_of(target);
  if (!kept || !paintable(x, y) || !scenery_mixes.is_mixed[at]) return;
  kept.is_mixed[at] = 1;
  kept.tops[at] = scenery_mixes.tops[at];
  kept.unders[at] = scenery_mixes.unders[at];
}

/* Reference#restore_patch */
function restore_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const x = left + col, y = top + row;
      if (on_screen(x, y)) put_back_cell(x, y);
    }
  }
}

function restore_turned_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    const line = turned_box_line(top, row);
    if (line >= 0) restore_patch(left, line, width, 1);
  }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over;
 * null when it is not on the picture. */
function forget_drawn_place(sprite) {
  fault_unless_sprite(sprite);
  const place = last_drawn[sprite];
  if (!place.drawn) return null;
  place.drawn = 0;
  return place;
}

/* Reference#restore_scene_rect */
function rg_object_take_off(sprite, width, height) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  restore_patch(place.x, place.y, width, height);
}

function rg_object_take_off_turned(sprite, image, resizes) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  const art = picture_of(image);
  const width = art.width, height = art.height;
  const middle_x = place.x + Math.trunc(width / 2), middle_y = place.y + Math.trunc(height / 2);
  if (resizes) {
    restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  const side = whole_root(width * width + height * height) + 2;
  restore_turned_patch(middle_x - Math.trunc(side / 2), middle_y - Math.trunc(side / 2), side, side);
}

function add_placed(placed) {
  fault_unless_sprite(placed.sprite);
  if (drawing.length >= RG_MAX_SPRITES) rg_fault(`more than ${RG_MAX_SPRITES} sprites on screen at once`);
  drawing.push(placed);
}

function rg_objects_add(sprite, image, x, y, level) {
  add_placed({ sprite, image, x, y, level, turned: 0, angle: 0, size: 0, resizes: 0 });
}

function rg_objects_add_turned(sprite, image, x, y, level, angle, size, resizes) {
  add_placed({ sprite, image, x, y, level, turned: 1, angle, size, resizes });
}

/* Whether the sprites a pass drew are the sprites the last rebuild painted, in the same places:
 * compared field by field as they are laid down, with nothing worked out. */
function same_sprites(drawn, kept) {
  if (drawn.length !== kept.length) return false;
  for (let i = 0; i < drawn.length; i++) {
    const a = drawn[i], b = kept[i];
    if (a.sprite !== b.sprite || a.image !== b.image || a.x !== b.x || a.y !== b.y || a.level !== b.level ||
        a.turned !== b.turned || a.angle !== b.angle || a.size !== b.size || a.resizes !== b.resizes) return false;
  }
  return true;
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
 * screen now are kept (#snapshot_object_layer) and the rebuild is owed, unless they are the
 * sprites, in the same places, that the last rebuild painted: the interpreter builds it every
 * time, and this only when something moved. */
function rg_objects_end() {
  mark_slices_left_out(drawing);
  const kept = sprite_layer;
  sprite_layer = drawing.slice();
  // Reference#show_objects_over_picture: in the layer in front of a painted picture, never into it.
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SPRITES_OVER_PICTURE]) {
    over_picture.fill(RG_NOTHING_IN_FRONT);
    paint_onto_plain_layer(over_picture);
    for (const placed of drawing) draw_placed(placed);
    paint_onto_plain_layer(null);
    over_picture_up = drawing.length > 0;
    return;
  }
  if (rebuilt_whole()) {
    if (!same_sprites(drawing, kept)) request_repaint();
    else skip_repaint();
    return;
  }
  // The sprite layer is off while a painted screen is up in a game with screens drawn from tiles.
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  for (const placed of drawing) {
    mix_as_sprite(placed.sprite);
    draw_placed(placed);
    mix_nothing();
    const place = last_drawn[placed.sprite];
    place.drawn = 1;
    place.x = placed.x;
    place.y = placed.y;
  }
}

const NO_PLACE = -1;
function place_named(said, count) {
  const place = said < 0 ? said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order */
function rg_place_in_ordered_run(said, count) {
  const place = place_named(said, count);
  if (place === NO_PLACE) rg_fault(`a draw order names sprite ${said} of the ${count} it puts in order`);
  return place;
}

/* Reference#collision_sprite */
function rg_pose_image(poses, count, pose) {
  const place = place_named(pose, count);
  if (place === NO_PLACE) rg_fault(`a sprite is showing picture ${pose} of its ${count}`);
  return poses[place];
}

/* Reference#pixels_overlap? */
function rg_pixels_overlap(a_image, a_x, a_y, b_image, b_x, b_y) {
  const a = picture_of(a_image), b = picture_of(b_image);
  const left = a_x > b_x ? a_x : b_x, top = a_y > b_y ? a_y : b_y;
  const a_right = a_x + a.width, b_right = b_x + b.width;
  const a_bottom = a_y + a.height, b_bottom = b_y + b.height;
  const right = a_right < b_right ? a_right : b_right, bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (let y = top; y < bottom; y++) {
    for (let x = left; x < right; x++) {
      if (a.pixels[a.start + (y - a_y) * a.width + (x - a_x)] !== RG_NOT_DRAWN &&
          b.pixels[b.start + (y - b_y) * b.width + (x - b_x)] !== RG_NOT_DRAWN) return 1;
    }
  }
  return 0;
}

/* --- a sprite in blocks (Reference::SpriteBlocks) --- */

/* The size of the blocks the sprite being painted is put into, asked once a sprite
 * (paint_kept_sprite), never once a pixel. */
let sprite_block = 1;

function block_start(at) { return at - floor_mod(at, sprite_block); }
function block_end(edge) { return -floor_div(-edge, sprite_block) * sprite_block; }

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

/* Reference#paint_snapshot_object: one of the sprites kept for a rebuild is drawn in blocks while
 * the picture is shown in them (rg_hook_block_size), unless the game leaves it as drawn. */
function paint_kept_sprite(placed) {
  sprite_block = rg_hook_block_size();
  if (sprite_block === 1 || rg_game_sprite_blocks[placed.sprite] === RG_NOT_IN_BLOCKS) draw_placed(placed);
  else if (placed.turned) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
}

/* --- the hooks it takes --- */

/* Reference#repaint_view, for sprites: the sprites kept for the rebuild that sit at this level, drawn
 * after the level's scenery (this feature comes after the tiled one). */
function rg_sprites_paint_level(level) {
  for (const placed of sprite_layer) {
    if (placed.level !== level) continue;
    mix_as_sprite(placed.sprite);
    fade_unless_left_as_drawn(rg_game_sprite_fade_places[placed.sprite]);
    paint_kept_sprite(placed);
  }
}

/* Reference#exec_screen: what was under each sprite went with the old screen, so nothing is put back
 * over the new one. A console that places its sprites at the end of a pass takes them off after this. */
function rg_sprites_screen_crossed(_new_kind) {
  for (const place of last_drawn) place.drawn = 0;
  over_picture_up = false;
}

/* Reference#sprites: what the game last put on screen. */
function rg_sprites_drawn_count() { return drawing.length; }

function rg_sprites_drawn_sprite(place) {
  const placed = drawing[place];
  return { name: rg_game_sprite_names[placed.sprite], picture: rg_game_image_pictures[placed.image], x: placed.x, y: placed.y };
}

/* Reference#redraw_sprites_over_arrived_scenery asks whether any sprite was kept when it was drawn. */
function rg_sprites_any_sprite_kept() { return sprite_layer.length > 0; }

/* Framebuffer#shown and #pixel, with sprites over a painted screen: the layer in front, while any
 * sprite is in it. */
function rg_sprites_front_layer() { return over_picture_up ? over_picture : null; }

/* --- the state image (rg_sprites.c says what each field holds) --- */

const PLACED_STATE_NUMBERS = 10, PLACED_SPRITE = 0, PLACED_IMAGE = 1, PLACED_CUT_COUNT = 9;
const CUT_NUMBERS = 2, DRAWN_PLACE_NUMBERS = 3;
const MOST_SLICES_LEFT_OUT = 16384; /* rg_sprites.c's MAX_LEFT_OUT */

function refuse_damaged_sprites(what) { rg_fault(`This state is damaged: ${what}. Load a state that this game wrote.`); }

/* The +count+ sprites of +placed+ as field +name+, and the slices left out of them as +cuts_name+;
 * gives back the sprites read, or +placed+ as it was when writing. +cuts_before+ slices were read
 * already for the other list. */
function visit_placed_objects(name, cuts_name, placed, count, cuts_before) {
  const reading = rg_state_reading();
  const numbers = reading ? new Array(count * PLACED_STATE_NUMBERS).fill(0) :
    placed.flatMap((p) => [p.sprite, p.image, p.x, p.y, p.level, p.turned ? 1 : 0, p.angle, p.size, p.resizes ? 1 : 0,
      p.cuts ? p.cuts.length : 0]);
  rg_state_numbers(name, numbers);
  let cut_total = 0;
  for (let i = 0; i < count; i++) {
    const n = numbers.slice(i * PLACED_STATE_NUMBERS, (i + 1) * PLACED_STATE_NUMBERS);
    if (n[PLACED_SPRITE] < 0 || n[PLACED_SPRITE] >= RG_MAX_SPRITES || n[PLACED_IMAGE] < 0 ||
        n[PLACED_IMAGE] >= rg_game_picture_sizes[RG_SIZE_IMAGES] || n[PLACED_CUT_COUNT] < 0) {
      refuse_damaged_sprites("a sprite names a sprite or a picture the game does not have");
    }
    cut_total += n[PLACED_CUT_COUNT];
  }
  if (cut_total > MOST_SLICES_LEFT_OUT - cuts_before) refuse_damaged_sprites("more slices of sprites are left out than can be");
  const cuts = reading ? new Array(cut_total * CUT_NUMBERS).fill(0) : placed.flatMap((p) => (p.cuts || []).flat());
  rg_state_numbers(cuts_name, cuts);
  if (!reading) return placed;
  let at = 0;
  return Array.from({ length: count }, (_, i) => {
    const n = numbers.slice(i * PLACED_STATE_NUMBERS, (i + 1) * PLACED_STATE_NUMBERS);
    const these = [];
    for (let k = 0; k < n[PLACED_CUT_COUNT]; k++, at += CUT_NUMBERS) these.push([cuts[at], cuts[at + 1]]);
    return { sprite: n[0], image: n[1], x: n[2], y: n[3], level: n[4], turned: n[5], angle: n[6], size: n[7], resizes: n[8],
      cuts: these.length > 0 ? these : null };
  });
}

/* rg_hook_visit_state (rg_sprites.c's rg_sprites_visit_state). */
function rg_sprites_visit_state() {
  const counts = [drawing.length, sprite_layer.length, over_picture_up ? 1 : 0];
  rg_state_numbers("sprites", counts);
  if (counts[0] < 0 || counts[0] > RG_MAX_SPRITES || counts[1] < 0 || counts[1] > RG_MAX_SPRITES) {
    refuse_damaged_sprites("more sprites are on screen than there is room for");
  }
  over_picture_up = counts[2] !== 0;
  drawing = visit_placed_objects("sprites.drawing", "sprites.drawing.cuts", drawing, counts[0], 0);
  const drawing_cuts = drawing.reduce((sum, p) => sum + (p.cuts ? p.cuts.length : 0), 0);
  sprite_layer = visit_placed_objects("sprites.kept", "sprites.kept.cuts", sprite_layer, counts[1], drawing_cuts);

  const places = last_drawn.flatMap((place) => [place.drawn ? 1 : 0, place.drawn ? place.x : 0, place.drawn ? place.y : 0]);
  rg_state_numbers("sprites.drawn_places", places);
  last_drawn.forEach((place, i) => {
    place.drawn = places[DRAWN_PLACE_NUMBERS * i] !== 0 ? 1 : 0;
    place.x = places[DRAWN_PLACE_NUMBERS * i + 1];
    place.y = places[DRAWN_PLACE_NUMBERS * i + 2];
  });

  const front = over_picture_up ? Array.from(over_picture) : new Array(over_picture.length).fill(RG_NOTHING_IN_FRONT);
  rg_state_numbers("sprites.over_picture", front);
  over_picture.set(front);
}
