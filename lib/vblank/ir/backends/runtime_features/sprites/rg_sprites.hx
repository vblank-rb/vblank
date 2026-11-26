/*
 * Sprites and their draw order (Reference#exec_present_objects and the sprites it keeps): joined into the runtime's
 * class after rg_screen.hx for a game that declares a sprite. This is rg_sprites.js written again, function for
 * function. It reads the screen's own state and painters as if it were written there.
 *
 * Left out: the state image (rg_sprites_visit_state stops the game in plain words), and the pieces of an image a
 * start file lists.
 */

static inline var RG_SIZE_SPRITES_OVER_PICTURE:Int = 10;
static inline var RG_NOT_IN_BLOCKS:Int = -1;

/* The sprites on screen this frame: being set (drawing), and as the last rebuild draws them. */
static var drawing:Array<RgPlaced> = [];
static var sprite_layer:Array<RgPlaced> = [];

/* Where each sprite was last drawn straight onto the picture (Reference @obj_prev). */
static var last_drawn:Array<RgDrawnPlace> = [for (i in 0...RG_MAX_SPRITES) new RgDrawnPlace()];

/* Sprites over a painted picture: one colour or RG_NOTHING_IN_FRONT for each place on the screen, in front of the
 * picture, painted as the screen's plain layer (paint_onto_plain_layer) and shown while +over_picture_up+
 * (rg_sprites_front_layer). */
static var over_picture:Vector<Int> = new Vector<Int>(RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT);
static var over_picture_up:Bool = false;

/* Reference#set_see_through_for, for a sprite: the see-through layer it was in as it was put on screen. */
static function mix_as_sprite(placed:RgPlaced):Void {
  mix_as_layer(placed.see_through);
  painting_sprite = 1;
}

/* Which rows of the screen the box of a turned sprite is shown on (Reference::TurnedBox). */
static inline var TURNED_BOX_LINES:Int = 256;

static function turned_box_line(top:Int, row:Int):Int {
  var line = floor_mod(top + row, TURNED_BOX_LINES);
  return line < RG_SCREEN_HEIGHT ? line : -1;
}

/* Ruby's Integer.sqrt */
static function whole_root(value:Int):Int {
  var root = Std.int(Math.floor(Math.sqrt(value)));
  while (root * root > value) root--;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

static function turned_box_on_screen(top:Int, width:Int, height:Int, resizes:Int):Bool {
  var first = 0;
  var past = height * 2;
  if (resizes == 0) {
    var reach = whole_root(width * width + height * height) + 2;
    first = height - Std.int(reach / 2);
    past = first + reach;
  }
  return top + past > 0 && top + first < RG_SCREEN_HEIGHT;
}

/* Reference#blit_image_transformed */
static function blit_image_turned(image:Int, x:Int, y:Int, angle:Int, size:Int, resizes:Int):Void {
  var art = picture_of(image);
  var width = art.width;
  var height = art.height;
  var one_th = rg_game_turn_rules[1];
  var matrix = affine_matrix(floor_mod(angle, 360), size);
  var turn_cos = matrix[0];
  var turn_sin = matrix[1];
  var left = x - Std.int(width / 2);
  var top = y - Std.int(height / 2);
  if (!turned_box_on_screen(top, width, height, resizes)) return;
  for (iy in 0...height * 2) {
    var line = turned_box_line(top, iy);
    if (line < 0) continue;
    var dy = iy - height;
    for (ix in 0...width * 2) {
      var dx = ix - width;
      var from_x = rg_floor_div(turn_cos * dx + turn_sin * dy, one_th) + Std.int(width / 2);
      var from_y = rg_floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Std.int(height / 2);
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      var color = picture_pixel(art, from_y * width + from_x);
      if (color != RG_NOT_DRAWN) set_pixel(left + ix, line, color);
    }
  }
}

/* --- how many sprites a line of the screen shows (Backends::SpriteLines) ---
 * rg_game_image_pieces: how many images are listed, the game's entry reach (piece_takes_entry), then where each
 * image's pieces start, and there how many, then each one's across, down, width and height.
 * RG_SPRITE_PIECES_A_LINE is 0 where every piece is drawn, RG_SPRITE_SLIVERS_A_LINE and RG_SPRITE_PIXELS_A_LINE 0
 * where those are not counted, and RG_SPRITE_PIECES_A_SCREEN 0 where the table holds every piece. */
static inline var SLIVER:Int = 8;
static inline var PIECE_NUMBERS:Int = 4;

static function image_pieces_start(image:Int):Int { return rg_game_image_pieces[2 + image]; }

static function piece_on_screen(left:Int, top:Int, width:Int, height:Int):Bool {
  return left > -width && left < RG_SCREEN_WIDTH && top > -height && top < RG_SCREEN_HEIGHT;
}

static function piece_takes_entry(left:Int, top:Int, width:Int, height:Int):Bool {
  var reach = rg_game_image_pieces[1];
  return piece_on_screen(left, top, width > reach ? width : reach, height > reach ? height : reach);
}

/* SpriteLines.limit_slivers */
static function limit_slivers(kept:Array<RgLinePiece>):Void {
  var fetched = 0;
  var i = kept.length - 1;
  while (i >= 0) {
    var offset = 0;
    while (offset < kept[i].width) {
      var sliver = kept[i].left + offset;
      if (sliver > -SLIVER && sliver < RG_SCREEN_WIDTH) {
        if (fetched == RG_SPRITE_SLIVERS_A_LINE) {
          kept[i].from = offset;
          break;
        }
        fetched++;
      }
      offset += SLIVER;
    }
    i--;
  }
}

/* SpriteLines.limit_pixels */
static function limit_pixels(kept:Array<RgLinePiece>):Void {
  var spent = 0;
  for (piece in kept) {
    if (spent + piece.width > RG_SPRITE_PIXELS_A_LINE) piece.from = RG_SPRITE_PIXELS_A_LINE - spent > 0 ? RG_SPRITE_PIXELS_A_LINE - spent : 0;
    spent += piece.width;
  }
}

/* Reference#mark_slices_left_out: each sprite that loses slices to a crowded line, or pieces to a full table, keeps
 * them as cuts, [line, piece, first column left out] each. The table lists them front-most first: the deepest level
 * last, and inside a level the one drawn last first, and is filled from the end RG_SPRITE_TABLE_FROM_BACK names.
 * Each line's pieces are gathered in that order, then held to the line's limit. */
static function mark_slices_left_out(placed:Array<RgPlaced>):Void {
  for (sprite in placed) sprite.cuts = null;
  if ((RG_SPRITE_PIECES_A_LINE == 0 && RG_SPRITE_PIECES_A_SCREEN == 0) || placed.length == 0) return;
  var order = [for (at in 0...placed.length) at];
  order.sort(function(a, b) return placed[b].level != placed[a].level ? placed[b].level - placed[a].level : b - a);
  var lines:Array<Array<RgLinePiece>> = [for (line in 0...RG_SCREEN_HEIGHT) []];
  var cuts_of = new haxe.ds.ObjectMap<RgPlaced, Array<Array<Int>>>();
  var note = function(sprite:RgPlaced, line:Int, piece:Int, from:Int):Void {
    if (!cuts_of.exists(sprite)) cuts_of.set(sprite, []);
    cuts_of.get(sprite).push([line, piece, from]);
  };
  var taking:Array<{sprite:RgPlaced, piece:Int, left:Int, top:Int, width:Int, height:Int}> = [];
  for (at in order) {
    var sprite = placed[at];
    var start = image_pieces_start(sprite.image);
    for (piece in 0...rg_game_image_pieces[start]) {
      var p = start + 1 + PIECE_NUMBERS * piece;
      var left = sprite.x + rg_game_image_pieces[p];
      var top = sprite.y + rg_game_image_pieces[p + 1];
      var width = rg_game_image_pieces[p + 2];
      var height = rg_game_image_pieces[p + 3];
      if (piece_takes_entry(left, top, width, height)) taking.push({sprite: sprite, piece: piece, left: left, top: top, width: width, height: height});
    }
  }
  for (at in 0...taking.length) {
    var entry = taking[at];
    var in_table = RG_SPRITE_PIECES_A_SCREEN == 0 ||
      (RG_SPRITE_TABLE_FROM_BACK != 0 ? at >= taking.length - RG_SPRITE_PIECES_A_SCREEN : at < RG_SPRITE_PIECES_A_SCREEN);
    if (!piece_on_screen(entry.left, entry.top, entry.width, entry.height)) continue;
    var first = entry.top > 0 ? entry.top : 0;
    var past = entry.top + entry.height < RG_SCREEN_HEIGHT ? entry.top + entry.height : RG_SCREEN_HEIGHT;
    for (line in first...past) {
      if (!in_table) note(entry.sprite, line, entry.piece, 0);
      else lines[line].push(new RgLinePiece(entry.sprite, entry.piece, entry.left, entry.width, entry.width));
    }
  }
  if (RG_SPRITE_PIECES_A_LINE != 0) {
    for (line in 0...RG_SCREEN_HEIGHT) {
      var pieces = lines[line];
      for (dropped in pieces.slice(RG_SPRITE_PIECES_A_LINE)) note(dropped.sprite, line, dropped.piece, 0);
      var kept = pieces.slice(0, RG_SPRITE_PIECES_A_LINE);
      if (RG_SPRITE_SLIVERS_A_LINE != 0) limit_slivers(kept);
      if (RG_SPRITE_PIXELS_A_LINE != 0) limit_pixels(kept);
      for (piece in kept) if (piece.from < piece.width) note(piece.sprite, line, piece.piece, piece.from);
    }
  }
  for (sprite in cuts_of.keys()) sprite.cuts = cuts_of.get(sprite);
}

/* SpriteLines.left_out_at?: left out where a piece covering it is left out of the line from that column, and no piece
 * drawn there covers it. */
static function left_out_at(placed:RgPlaced, col:Int, row:Int, line:Int):Bool {
  var start = image_pieces_start(placed.image);
  var covered = false;
  for (piece in 0...rg_game_image_pieces[start]) {
    var p = start + 1 + PIECE_NUMBERS * piece;
    var across = rg_game_image_pieces[p];
    var down = rg_game_image_pieces[p + 1];
    if (col < across || col >= across + rg_game_image_pieces[p + 2] || row < down || row >= down + rg_game_image_pieces[p + 3]) continue;
    var cut_here = false;
    for (cut in placed.cuts) {
      if (cut[0] == line && cut[1] == piece && col - across >= cut[2]) cut_here = true;
    }
    if (!cut_here) return false;
    covered = true;
  }
  return covered;
}

/* Reference#blit_image with a sprite's slices left out. */
static function blit_with_slices_left_out(placed:RgPlaced):Void {
  var art = picture_of(placed.image);
  for (row in 0...art.height) {
    for (col in 0...art.width) {
      var color = picture_pixel(art, row * art.width + col);
      if (color != RG_NOT_DRAWN && !left_out_at(placed, col, row, placed.y + row)) set_pixel(placed.x + col, placed.y + row, color);
    }
  }
}

/* Reference#draw_object and #paint_snapshot_object */
static function draw_placed(placed:RgPlaced):Void {
  if (placed.turned != 0) blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes);
  else if (placed.cuts != null) blit_with_slices_left_out(placed);
  else blit_image(placed.image, placed.x, placed.y);
}

/* Reference#scene_framebuffer: the backdrop, and every background showing stamped over it (rg_hook_stamp_scenery). */
static function keep_scenery():Void {
  if (scenery_kept != 0) return;
  var outer = [area_in_force, area_left, area_top, area_right, area_bottom];
  area_in_force = 0;
  area_left = 0;
  area_top = 0;
  area_right = 0;
  area_bottom = 0;
  target = scenery;
  clear_to(backdrop);
  rg_hook_stamp_scenery();
  target = pixels;
  area_in_force = outer[0];
  area_left = outer[1];
  area_top = outer[2];
  area_right = outer[3];
  area_bottom = outer[4];
  scenery_kept = 1;
}

/* The start of Reference#exec_present_objects */
static function rg_objects_begin():Void {
  drawing = [];
  if (rebuilt_whole() == 0) keep_scenery();
}

static function fault_unless_sprite(sprite:Int):Void {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault("sprite number " + sprite + " is not one of the " + RG_MAX_SPRITES + " there is room for");
}

/* Framebuffer#put_back_cell */
static function put_back_cell(x:Int, y:Int):Void {
  var at = y * RG_SCREEN_WIDTH + x;
  set_pixel(x, y, scenery[at]);
  var kept = mixes_of(target);
  if (kept == null || !paintable(x, y) || scenery_mixes.is_mixed[at] == 0) return;
  kept.is_mixed[at] = 1;
  kept.tops[at] = scenery_mixes.tops[at];
  kept.unders[at] = scenery_mixes.unders[at];
}

/* Reference#restore_patch */
static function restore_patch(left:Int, top:Int, width:Int, height:Int):Void {
  for (row in 0...height) {
    for (col in 0...width) {
      var x = left + col;
      var y = top + row;
      if (on_screen(x, y)) put_back_cell(x, y);
    }
  }
}

static function restore_turned_patch(left:Int, top:Int, width:Int, height:Int):Void {
  for (row in 0...height) {
    var line = turned_box_line(top, row);
    if (line >= 0) restore_patch(left, line, width, 1);
  }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over; null when it is not on
 * the picture. */
static function forget_drawn_place(sprite:Int):RgDrawnPlace {
  fault_unless_sprite(sprite);
  var place = last_drawn[sprite];
  if (place.drawn == 0) return null;
  place.drawn = 0;
  return place;
}

/* Reference#restore_scene_rect */
static function rg_object_take_off(sprite:Int, width:Int, height:Int):Void {
  var place = forget_drawn_place(sprite);
  if (place == null) return;
  restore_patch(place.x, place.y, width, height);
}

static function rg_object_take_off_turned(sprite:Int, image:Int, resizes:Int):Void {
  var place = forget_drawn_place(sprite);
  if (place == null) return;
  var art = picture_of(image);
  var width = art.width;
  var height = art.height;
  var middle_x = place.x + Std.int(width / 2);
  var middle_y = place.y + Std.int(height / 2);
  if (resizes != 0) {
    restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  var side = whole_root(width * width + height * height) + 2;
  restore_turned_patch(middle_x - Std.int(side / 2), middle_y - Std.int(side / 2), side, side);
}

static function add_placed(placed:RgPlaced):Void {
  fault_unless_sprite(placed.sprite);
  if (drawing.length >= RG_MAX_SPRITES) rg_fault("more than " + RG_MAX_SPRITES + " sprites on screen at once");
  drawing.push(placed);
}

static function rg_objects_add(sprite:Int, image:Int, x:Int, y:Int, level:Int, see_through:Int, fade_place:Int):Void {
  add_placed(new RgPlaced(sprite, image, x, y, level, see_through, fade_place, 0, 0, 0, 0));
}

static function rg_objects_add_turned(sprite:Int, image:Int, x:Int, y:Int, level:Int, see_through:Int, fade_place:Int, angle:Int, size:Int, resizes:Int):Void {
  add_placed(new RgPlaced(sprite, image, x, y, level, see_through, fade_place, 1, angle, size, resizes));
}

/* Whether the sprites a pass drew are the sprites the last rebuild painted, in the same places. */
static function same_sprites(drawn:Array<RgPlaced>, kept:Array<RgPlaced>):Bool {
  if (drawn.length != kept.length) return false;
  for (i in 0...drawn.length) {
    var a = drawn[i];
    var b = kept[i];
    if (a.sprite != b.sprite || a.image != b.image || a.x != b.x || a.y != b.y || a.level != b.level ||
        a.see_through != b.see_through || a.fade_place != b.fade_place ||
        a.turned != b.turned || a.angle != b.angle || a.size != b.size || a.resizes != b.resizes) return false;
  }
  return true;
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on screen now are kept
 * (#snapshot_object_layer) and the rebuild is owed, unless they are the sprites, in the same places, that the last
 * rebuild painted: the interpreter builds it every time, and this only when something moved. */
static function rg_objects_end():Void {
  mark_slices_left_out(drawing);
  var kept = sprite_layer;
  sprite_layer = drawing.copy();
  // Reference#show_objects_over_picture: in the layer in front of a painted picture, never into it.
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SPRITES_OVER_PICTURE] != 0) {
    for (i in 0...over_picture.length) over_picture[i] = RG_NOTHING_IN_FRONT;
    paint_onto_plain_layer(over_picture);
    for (placed in drawing) draw_placed(placed);
    paint_onto_plain_layer(null);
    over_picture_up = drawing.length > 0;
    return;
  }
  if (rebuilt_whole() != 0) {
    if (!same_sprites(drawing, kept)) request_repaint();
    else skip_repaint();
    return;
  }
  // The sprite layer is off while a painted screen is up in a game with screens drawn from tiles.
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0) return;
  for (placed in drawing) {
    mix_as_sprite(placed);
    draw_placed(placed);
    mix_nothing();
    var place = last_drawn[placed.sprite];
    place.drawn = 1;
    place.x = placed.x;
    place.y = placed.y;
  }
}

static inline var NO_PLACE:Int = -1;
static function place_named(said:Int, count:Int):Int {
  var place = said < 0 ? said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order */
static function rg_place_in_ordered_run(said:Int, count:Int):Int {
  var place = place_named(said, count);
  if (place == NO_PLACE) rg_fault("a draw order names sprite " + said + " of the " + count + " it puts in order");
  return place;
}

/* Reference#collision_sprite */
static function rg_pose_image(poses:Vector<Int>, count:Int, pose:Int):Int {
  var place = place_named(pose, count);
  if (place == NO_PLACE) rg_fault("a sprite is showing picture " + pose + " of its " + count);
  return poses[place];
}

/* Reference#pixels_overlap? */
static function rg_pixels_overlap(a_image:Int, a_x:Int, a_y:Int, b_image:Int, b_x:Int, b_y:Int):Int {
  var a = picture_of(a_image);
  var b = picture_of(b_image);
  var left = a_x > b_x ? a_x : b_x;
  var top = a_y > b_y ? a_y : b_y;
  var a_right = a_x + a.width;
  var b_right = b_x + b.width;
  var a_bottom = a_y + a.height;
  var b_bottom = b_y + b.height;
  var right = a_right < b_right ? a_right : b_right;
  var bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (y in top...bottom) {
    for (x in left...right) {
      if (a.pixels[a.start + (y - a_y) * a.width + (x - a_x)] != RG_NOT_DRAWN &&
          b.pixels[b.start + (y - b_y) * b.width + (x - b_x)] != RG_NOT_DRAWN) return 1;
    }
  }
  return 0;
}

/* --- a sprite in blocks (Reference::SpriteBlocks) --- */

/* The size of the blocks the sprite being painted is put into, asked once a sprite (paint_kept_sprite), never once a
 * pixel. */
static var sprite_block:Int = 1;

static function block_start(at:Int):Int { return at - floor_mod(at, sprite_block); }
static function block_end(edge:Int):Int { return -rg_floor_div(-edge, sprite_block) * sprite_block; }

static function picture_color(art:RgArt, col:Int, row:Int):Int {
  if (col < 0 || col >= art.width || row < 0 || row >= art.height) return RG_NOT_DRAWN;
  return picture_pixel(art, row * art.width + col);
}

/* SpriteBlocks#paint_box */
static function paint_box_in_blocks(art:RgArt, x:Int, y:Int, left:Int, top:Int, width:Int, height:Int):Void {
  var first_row = top > 0 ? top : 0;
  var past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT;
  var first_col = left > 0 ? left : 0;
  var past_col = block_end(left + width);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  for (py in first_row...past_row) {
    var from_y = clamp_number(block_start(py), top, top + height - 1);
    for (px in first_col...past_col) {
      var color = picture_color(art, clamp_number(block_start(px), left, left + width - 1) - x, from_y - y);
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* SpriteBlocks#paint_upright */
static function paint_upright_in_blocks(placed:RgPlaced):Void {
  var listed = rg_game_sprite_blocks[placed.sprite];
  var pictures = rg_game_sprite_boxes[listed++];
  var showing_picture = rg_game_image_pictures[placed.image];
  for (i in 0...pictures) {
    var name = rg_game_sprite_boxes[listed];
    var boxes = rg_game_sprite_boxes[listed + 1];
    var box = listed + 2;
    listed = box + 4 * boxes;
    if (name != showing_picture) continue;
    var art = picture_of(placed.image);
    var b = boxes - 1;
    while (b >= 0) {
      paint_box_in_blocks(art, placed.x, placed.y, placed.x + rg_game_sprite_boxes[box + 4 * b],
        placed.y + rg_game_sprite_boxes[box + 4 * b + 1], rg_game_sprite_boxes[box + 4 * b + 2],
        rg_game_sprite_boxes[box + 4 * b + 3]);
      b--;
    }
    return;
  }
  rg_fault("sprite " + placed.sprite + " is shown in blocks and has no boxes for the picture it shows");
}

/* SpriteBlocks#turned_row */
static function turned_row(py:Int, top:Int, height:Int):Int {
  var lines = 256;
  var first = floor_mod(top, lines);
  var past = first + height;
  var line = block_start(py);
  if (line < first && first < RG_SCREEN_HEIGHT) line = first;
  if (line >= past % lines) line = past - 1;
  return floor_mod(line - first, lines);
}

/* SpriteBlocks#paint_turned */
static function paint_turned_in_blocks(placed:RgPlaced):Void {
  var art = picture_of(placed.image);
  var width = art.width;
  var height = art.height;
  var one_th = rg_game_turn_rules[1];
  var matrix = affine_matrix(floor_mod(placed.angle, 360), placed.size);
  var turn_cos = matrix[0];
  var turn_sin = matrix[1];
  var left = placed.x - Std.int(width / 2);
  var top = placed.y - Std.int(height / 2);
  var first_col = left > 0 ? left : 0;
  var past_col = block_end(left + width * 2);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  if (!turned_box_on_screen(top, width, height, placed.resizes)) return;
  for (iy in 0...height * 2) {
    var py = turned_box_line(top, iy);
    if (py < 0) continue;
    var dy = turned_row(py, top, height * 2) - height;
    for (px in first_col...past_col) {
      var start = block_start(px);
      var dx = (start >= left ? start : left - 1) - left - width;
      var color = picture_color(art, rg_floor_div(turn_cos * dx + turn_sin * dy, one_th) + Std.int(width / 2),
        rg_floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Std.int(height / 2));
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* Reference#paint_snapshot_object: one of the sprites kept for a rebuild is drawn in blocks while the picture is shown
 * in them (rg_hook_block_size), unless the game leaves it as drawn. */
static function paint_kept_sprite(placed:RgPlaced):Void {
  sprite_block = rg_hook_block_size();
  if (sprite_block == 1 || rg_game_sprite_blocks[placed.sprite] == RG_NOT_IN_BLOCKS) draw_placed(placed);
  else if (placed.turned != 0) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
}

/* --- the hooks it takes --- */

/* Reference#repaint_view, for sprites: the sprites kept for the rebuild that sit at this level, drawn after the
 * level's scenery (this feature comes after the tiled one). */
static function rg_sprites_paint_level(level:Int):Void {
  for (placed in sprite_layer) {
    if (placed.level != level) continue;
    mix_as_sprite(placed);
    fade_unless_left_as_drawn(placed.fade_place);
    paint_kept_sprite(placed);
  }
}

/* Reference#paint_sprites_in_front */
static function rg_sprites_repaint_ending():Void {
  for (placed in sprite_layer) {
    if (rg_game_sprites_in_front[placed.sprite] == 0) continue;
    mix_as_sprite(placed);
    fade_unless_left_as_drawn(placed.fade_place);
    paint_kept_sprite(placed);
  }
}

/* Reference#exec_screen: what was under each sprite went with the old screen, so nothing is put back over the new one. */
static function rg_sprites_screen_crossed(_new_kind:Int):Void {
  for (place in last_drawn) place.drawn = 0;
  over_picture_up = false;
}

/* Reference#sprites: what the game last put on screen. */
static function rg_sprites_drawn_count():Int { return drawing.length; }

static function rg_sprites_drawn_sprite(place:Int):RgDrawnSprite {
  var placed = drawing[place];
  return new RgDrawnSprite(rg_game_sprite_names[placed.sprite], rg_game_image_pictures[placed.image], placed.x, placed.y);
}

/* Reference#redraw_sprites_over_arrived_scenery asks whether any sprite was kept when it was drawn. */
static function rg_sprites_any_sprite_kept():Bool { return sprite_layer.length > 0; }

/* Framebuffer#shown and #pixel, with sprites over a painted screen: the layer in front, while any sprite is in it. */
static function rg_sprites_front_layer():Vector<Int> { return over_picture_up ? over_picture : null; }

/* The state image is not written in Flash yet. */
static function rg_sprites_visit_state():Void { rg_state_refuse(); }
