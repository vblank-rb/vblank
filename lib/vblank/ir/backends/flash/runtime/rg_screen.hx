/*
 * The game's picture, drawn in software: the console's screen as an array of colors, and everything the
 * game does to it. A port of the JavaScript runtime's rg_screen.js, which is itself a port of the
 * interpreter's picture (backends/reference.rb and reference/framebuffer.rb) — each function names the
 * interpreter's method it follows, because that is what decides what is right here.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest.
 *
 * What it does not draw yet: the features that are not ported (a game that needs one is refused for by name).
 */

static inline var RG_CELLS:Int = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;

static inline var RG_BITMAP:Int = 0;
static inline var RG_TILED:Int = 1;
static inline var RG_ROTOZOOM:Int = 2;

static inline var RG_NO_LAYER:Int = -1;
static inline var RG_SIZE_DEPTHS:Int = 1;
static inline var RG_SIZE_SEE_THROUGH:Int = 4;
static inline var RG_SIZE_SCREEN_KINDS_CHANGE:Int = 5;
static inline var RG_ST_AMOUNTS_WRITTEN:Int = 0;
static inline var RG_ST_ONE_AMOUNT:Int = 1;
static inline var RG_ST_HOLDS_A_SPRITE:Int = 2;
static inline var RG_ST_SUBTRACTS:Int = 3;
static inline var RG_ST_FIELDS:Int = 4;
static inline var RG_MAX_SEE_THROUGH:Int = 16;

/* Where choice number +which+ is in a row that holds a sprite's own first and then +others+ more. */
static function rg_place_of_choice(which:Int, others:Int):Int { return which >= 0 && which < others ? which + 1 : 0; }

/* Two colors for a line of text, and the test that picks which. */
static function rg_pick_color(showing:Int, color:Int, picked:Int):Int { return showing != 0 ? picked : color; }

/* Two pages, or one (Framebuffer#paged=). Drawing always lands on +pixels+ and the viewer always reads
 * +viewed+; with one page those are the same picture. */
static var first_page:Vector<Int> = new Vector<Int>(RG_CELLS);
static var second_page:Vector<Int> = new Vector<Int>(RG_CELLS);
static var pixels:Vector<Int> = first_page;
static var viewed:Vector<Int> = first_page;
static var shown:Vector<Int> = new Vector<Int>(RG_CELLS);

/* The part of the screen drawing is held inside, and the areas in force around it. */
static var area_in_force:Int = 0;
static var area_left:Int = 0;
static var area_top:Int = 0;
static var area_right:Int = 0;
static var area_bottom:Int = 0;
static var outer_areas:Array<Array<Int>> = [];
static inline var AREAS_DEEP:Int = 64;

static var camera_x:Int = 0;
static var camera_y:Int = 0;

/* How much of the top left of the picture the window shows. */
static var shown_width:Int = RG_SCREEN_WIDTH;
static var shown_height:Int = RG_SCREEN_HEIGHT;

/* The patches of picture saved under bitmap sprites, by buffer number. */
static inline var NO_CELL:Int = -1;
static var saved_patches:Array<Vector<Int>> = [];

static var held:Int = 0;
static var frames_begun:Int = 0;
static var kind:Int = -1;
static var owed:Int = 0;
static var repaints_painted:Int = 0; /* how many times the whole view was built again */
static var rebuild_skipped:Int = 0;
static var picture_touched:Int = 0;
static var backdrop:Int = 0; /* the colour shown wherever nothing is drawn (Reference @backdrop) */
static var current_scene:Int = -1;

/* What is painted from here on is mixed with what is already in the cell (Framebuffer @through). */
static var mixing:Int = 0;
static var mixed_by:RgShares = new RgShares(0, 0);

/* The two colors each mixed cell was mixed from (Framebuffer @mixed_tops). */
static var picture_mixes:RgMixedSides = new RgMixedSides(RG_CELLS);
static var scenery_mixes:RgMixedSides = new RgMixedSides(RG_CELLS);
static var mixed_cells_by:RgShares = new RgShares(0, 0);

/* The picture with no sprites on it (Framebuffer @scenery). */
static var picture_without_sprites:Vector<Int> = new Vector<Int>(RG_CELLS);
static var painting_sprite:Int = 0;

/* --- the picture itself (Framebuffer) --- */

static inline function on_screen(x:Int, y:Int):Bool { return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT; }

static function paintable(x:Int, y:Int):Bool {
  if (!on_screen(x, y)) return false;
  return area_in_force == 0 || (x >= area_left && x < area_right && y >= area_top && y < area_bottom);
}

/* Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back under a sprite
 * (Reference#drawing_into). */
static var scenery:Vector<Int> = new Vector<Int>(RG_CELLS);
static var target:Vector<Int> = first_page;

/* A layer a feature paints into as it is, while one is handed over (paint_onto_plain_layer, null to give it back): a
 * screen's worth of cells, each painted pixel stored whole there and nowhere else, with no area, mix or fade. */
static var plain_layer:Vector<Int> = null;

static function paint_onto_plain_layer(layer:Vector<Int>):Void { plain_layer = layer; }

static inline function widened(channel:Int):Int { return (channel << 3) | (channel >> 2); }

/* Framebuffer#mix_see_through */
static function mixed_with_under(color:Int, under:Int, by:RgShares):Int {
  var out = 0;
  for (channel in 0...3) {
    var have = widened((color >> (5 * channel)) & 0x1F);
    var below = widened((under >> (5 * channel)) & 0x1F);
    var mix = clamp_number(rg_floor_div(have * by.painted + below * by.under, 16), 0, 255);
    out |= (mix >> 3) << (5 * channel);
  }
  return out;
}

/* Framebuffer#darkened_by_display: done in the channel's own byte as the interpreter does it. */
static function darkened_by_display(color:Int, steps:Int):Int {
  if (steps == 0) return color;
  var packed = 0;
  for (channel in 0...3) {
    var shift = channel * 5;
    var places = 1 << (channel * 8);
    var placed = widened((color >> shift) & 0x1F) * places;
    var kept = rg_floor_div(placed - Std.int((placed * steps) / 16), places);
    packed |= (kept >> 3) << shift;
  }
  return packed;
}

static function mixes_of(page:Vector<Int>):RgMixedSides {
  if (page == pixels) return picture_mixes;
  return page == scenery ? scenery_mixes : null;
}

/* Framebuffer#blend_into_cell */
static function into_cell(color:Int, under:Int, page:Vector<Int>, at:Int):Int {
  var painted = faded_as_painted(color);
  var kept = mixes_of(page);
  if (kept != null) {
    kept.is_mixed[at] = mixing;
    if (mixing != 0) {
      kept.tops[at] = painted;
      kept.unders[at] = under;
    }
  }
  return mixing != 0 ? mixed_with_under(painted, under, mixed_by) : painted;
}

/* Reference#see_through_sprites?, worked out once. */
static var sprites_seen_through_answer:Int = -1;
static function sprites_seen_through():Int {
  if (sprites_seen_through_answer >= 0) return sprites_seen_through_answer;
  sprites_seen_through_answer = 0;
  for (layer in 0...rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]) {
    if (rg_game_see_through[layer * RG_ST_FIELDS + RG_ST_HOLDS_A_SPRITE] != 0) sprites_seen_through_answer = 1;
  }
  return sprites_seen_through_answer;
}

static function keeps_picture_without_sprites():Bool { return target != scenery && sprites_seen_through() != 0; }

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. */
static function set_pixel(x:Int, y:Int, color:Int):Void {
  if (plain_layer != null) {
    if (on_screen(x, y)) plain_layer[y * RG_SCREEN_WIDTH + x] = color;
    return;
  }
  if (!paintable(x, y)) return;
  picture_touched = 1;
  var at = y * RG_SCREEN_WIDTH + x;
  var kept = keeps_picture_without_sprites();
  var under = kept && painting_sprite != 0 ? picture_without_sprites : target;
  var painted = into_cell(color, under[at], target, at);
  target[at] = painted;
  if (kept && painting_sprite == 0) picture_without_sprites[at] = painted;
}

/* Framebuffer#fill_rect */
static function fill_cells(x:Int, y:Int, width:Int, height:Int, color:Int):Void {
  var left = x < 0 ? 0 : x;
  var top = y < 0 ? 0 : y;
  // The far edge is worked out as a float: a corner and a size that sum past 32 bits are cut to the screen, not wrapped.
  var far_x:Float = (x:Float) + width;
  var far_y:Float = (y:Float) + height;
  var right:Int = far_x > RG_SCREEN_WIDTH ? RG_SCREEN_WIDTH : Std.int(far_x);
  var bottom:Int = far_y > RG_SCREEN_HEIGHT ? RG_SCREEN_HEIGHT : Std.int(far_y);
  for (py in top...bottom) {
    for (px in left...right) set_pixel(px, py, color);
  }
}

/* Framebuffer#clear */
static function clear_to(color:Int):Void {
  if (area_in_force != 0) {
    fill_cells(area_left, area_top, area_right - area_left, area_bottom - area_top, color);
    return;
  }
  picture_touched = 1;
  var painted = faded_as_painted(color);
  for (at in 0...RG_CELLS) target[at] = painted;
  var kept = mixes_of(target);
  if (kept != null) for (at in 0...RG_CELLS) kept.is_mixed[at] = 0;
  if (!keeps_picture_without_sprites()) return;
  for (at in 0...RG_CELLS) picture_without_sprites[at] = painted;
}

static function rg_screen_clear(color:Int):Void { clear_to(color); }
static function rg_screen_fill_rect(x:Int, y:Int, width:Int, height:Int, color:Int):Void { fill_cells(x, y, width, height, color); }

/* A sum of positions held to what an Int holds, where a float sum would pass it: an edge past every pixel is as good as any. */
static function rg_held_sum(a:Int, b:Int):Int {
  var sum:Float = (a:Float) + b;
  return sum > RG_INT32_MAX ? RG_INT32_MAX : (sum < RG_INT32_MIN ? RG_INT32_MIN : Std.int(sum));
}

static function rg_screen_inside(x:Int, y:Int, width:Int, height:Int):Void {
  if (outer_areas.length >= AREAS_DEEP) rg_fault("more than " + AREAS_DEEP + " `inside` blocks are open at once");
  outer_areas.push([area_in_force, area_left, area_top, area_right, area_bottom]);
  area_in_force = 1;
  area_left = x;
  area_top = y;
  area_right = rg_held_sum(x, width);
  area_bottom = rg_held_sum(y, height);
}

static function rg_screen_inside_ended():Void {
  var outer = outer_areas.pop();
  area_in_force = outer[0];
  area_left = outer[1];
  area_top = outer[2];
  area_right = outer[3];
  area_bottom = outer[4];
}

static function rg_screen_camera(x:Int, y:Int):Void {
  camera_x = x;
  camera_y = y;
}

static function rg_screen_show_size(width:Int, height:Int):Void {
  shown_width = width;
  shown_height = height;
}

static function rg_screen_camera_x():Int { return camera_x; }
static function rg_screen_camera_y():Int { return camera_y; }

/* Framebuffer#paged= */
static function show_pages(two:Int):Void {
  if (two == (pixels != viewed ? 1 : 0)) return;
  if (two == 0) {
    viewed = pixels;
    return;
  }
  viewed = pixels == first_page ? second_page : first_page;
  for (at in 0...RG_CELLS) viewed[at] = 0;
}

/* Reference#exec_save_region */
static function rg_patch_save(buffer:Int, width:Int, height:Int, x:Int, y:Int):Void {
  while (saved_patches.length <= buffer) saved_patches.push(null);
  if (saved_patches[buffer] == null) saved_patches[buffer] = new Vector<Int>(width * height > 1 ? width * height : 1);
  var patch = saved_patches[buffer];
  for (row in 0...height) {
    for (col in 0...width) {
      var px = x + col;
      var py = y + row;
      patch[row * width + col] = on_screen(px, py) ? pixels[py * RG_SCREEN_WIDTH + px] : NO_CELL;
    }
  }
}

/* Reference#exec_restore_region */
static function rg_patch_restore(buffer:Int, width:Int, height:Int, x:Int, y:Int):Void {
  var patch = buffer < saved_patches.length ? saved_patches[buffer] : null;
  if (patch == null) return;
  for (row in 0...height) {
    for (col in 0...width) {
      var color = patch[row * width + col];
      if (color != NO_CELL) set_pixel(x + col, y + row, color);
    }
  }
}

static function rg_screen_pixel(x:Int, y:Int, color:Int):Void { set_pixel(x, y, color); }

/* Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. */
static function rg_screen_points(x:Int, y:Int, color:Int, points:Vector<Int>, count:Int, first:Int = 0):Void {
  for (i in 0...count) set_pixel(x + points[2 * (first + i)], y + points[2 * (first + i) + 1], color);
}

/* Reference#exec_draw_digit */
static function rg_screen_digit(value:Int, x:Int, y:Int, color:Int, points:Vector<Int>, starts:Vector<Int>):Void {
  if (value < 0 || value > 9) return;
  rg_screen_points(x, y, color, points, starts[value + 1] - starts[value], starts[value]);
}

/* --- pictures --- */

static inline var RG_IMAGE_FIELDS:Int = 4;
static inline var RG_NO_IMAGE_COLORS:Int = -1;
static inline var RG_NOT_DRAWN:Int = -1;

/* Reference#blit_image: the picture +image+ (rg_screen.h says how the lowering lays them out in
 * rg_game_images and rg_game_image_pixels), each pixel it draws, from its top left. A pixel is the colour
 * itself, or a place in the picture's own colours where it has some. */
static function blit_image(image:Int, x:Int, y:Int):Void {
  var info = RG_IMAGE_FIELDS * image;
  var width = rg_game_images[info + 1];
  var height = rg_game_images[info + 2];
  var painted = image < painted_images.length ? painted_images[image] : null;
  var pixels_of:Vector<Int> = painted != null ? painted : rg_game_image_pixels;
  var start = painted != null ? 0 : rg_game_images[info];
  var colors = painted != null ? RG_NO_IMAGE_COLORS : rg_game_images[info + 3];
  for (row in 0...height) {
    for (col in 0...width) {
      var held = pixels_of[start + row * width + col];
      if (held == RG_NOT_DRAWN) continue;
      set_pixel(x + col, y + row, colors == RG_NO_IMAGE_COLORS ? held : pixels_of[colors + held]);
    }
  }
}

/* One picture: its pixels (a vector and where in it they start), its size, and where in that vector the colours of its
 * places start where its pixels are places (RG_NO_IMAGE_COLORS where they are colours). */
static function picture_of(image:Int):RgArt {
  var info = RG_IMAGE_FIELDS * image;
  var painted = image < painted_images.length ? painted_images[image] : null;
  if (painted != null) return new RgArt(painted, 0, rg_game_images[info + 1], rg_game_images[info + 2], RG_NO_IMAGE_COLORS);
  return new RgArt(rg_game_image_pixels, rg_game_images[info], rg_game_images[info + 1], rg_game_images[info + 2], rg_game_images[info + 3]);
}

/* The colour a picture shows at pixel +at+ of itself, or RG_NOT_DRAWN. */
static function picture_pixel(art:RgArt, at:Int):Int {
  var held = art.pixels[art.start + at];
  return art.colors != RG_NO_IMAGE_COLORS && held != RG_NOT_DRAWN ? art.pixels[art.colors + held] : held;
}

/* The images the game has painted, by image number (Reference#store_run_picture): each made again from the places
 * of its run, in its own colours. */
static var painted_images:Array<Vector<Int>> = [];

/* Reference#run_tile_places */
static function read_tile_places(list:RgList, which:Int, planes:Int, places:Vector<Int>, into:Int):Void {
  if (planes > 0) {
    var first = which * planes * 8;
    for (pixel in 0...RUN_TILE_PIXELS) {
      var place = 0;
      for (plane in 0...planes) {
        var index = first + (plane >> 1) * 16 + (pixel >> 3) * 2 + (plane & 1);
        var byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
        place |= ((byte >> (7 - (pixel & 7))) & 1) << plane;
      }
      places[into + pixel] = place;
    }
    return;
  }
  for (at in 0...Std.int(RUN_TILE_PIXELS / 2)) {
    var index = which * Std.int(RUN_TILE_PIXELS / 2) + at;
    var byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
    places[into + 2 * at] = byte & 0x0F;
    places[into + 2 * at + 1] = byte >> 4;
  }
}

/* Which runs' images have been painted from their places, by run. */
static var runs_painted:Vector<Int> = null;

/* Every image that is a painted picture's run made again from its places, each in its own colours. */
static function paint_run_images(run:Int):Void {
  if (runs_painted == null) runs_painted = new Vector<Int>(rg_game_picture_sizes[RG_SIZE_RUNS] + 1);
  runs_painted[run] = 1;
  var start = places_of(run);
  var area = run_field(run, RG_RUN_WIDTH) * run_field(run, RG_RUN_HEIGHT);
  for (i in 0...run_field(run, RG_RUN_IMAGES)) {
    var shown_as = (run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS;
    var image = rg_game_run_images[shown_as];
    while (painted_images.length <= image) painted_images.push(null);
    if (painted_images[image] == null) painted_images[image] = new Vector<Int>(area > 0 ? area : 1);
    var into = painted_images[image];
    for (at in 0...area) into[at] = rg_game_run_images[shown_as + 1 + painted_places[start + at]];
  }
}

/* Reference#copy_run_tiles */
static function rg_tiles_copy(run:Int, list:RgList):Void {
  var start = places_of(run);
  var width = run_field(run, RG_RUN_WIDTH);
  var height = run_field(run, RG_RUN_HEIGHT);
  if (width == 0) {
    for (which in 0...run_field(run, RG_RUN_TILES)) {
      read_tile_places(list, which, run_field(run, RG_RUN_PLANES), painted_places, start + which * RUN_TILE_PIXELS);
    }
    return;
  }
  var across = Std.int(width / RUN_TILE_SIDE);
  var tile = new Vector<Int>(RUN_TILE_PIXELS);
  for (which in 0...across * Std.int(height / RUN_TILE_SIDE)) {
    read_tile_places(list, which, run_field(run, RG_RUN_PLANES), tile, 0);
    var left = (which % across) * RUN_TILE_SIDE;
    var top = Std.int(which / across) * RUN_TILE_SIDE;
    for (i in 0...RUN_TILE_PIXELS) {
      painted_places[start + (top + Std.int(i / RUN_TILE_SIDE)) * width + left + (i % RUN_TILE_SIDE)] = tile[i];
    }
  }
  paint_run_images(run);
}

/* rg_tile_pose_load in the native runtime (Reference#exec_load_sprite_tiles, for one pose). */
static function rg_tile_pose_load(run:Int, pieces:Vector<Int>, piece_count:Int, table:Vector<Int>, kept:Int, at:Int, to:Int, count:Int):Void {
  var start = places_of(run);
  var width = run_field(run, RG_RUN_WIDTH);
  for (piece in 0...piece_count) {
    var dx = pieces[3 * piece];
    var dy = pieces[3 * piece + 1];
    var tile = pieces[3 * piece + 2];
    if (tile < to || tile >= to + count) continue;
    var first = (at + tile - to) * Std.int(RUN_TILE_PIXELS / 2);
    for (byte_at in 0...Std.int(RUN_TILE_PIXELS / 2)) {
      var byte = table[first + byte_at] & 0xFF;
      var row = Std.int(byte_at / Std.int(RUN_TILE_SIDE / 2));
      var col = (byte_at % Std.int(RUN_TILE_SIDE / 2)) * 2;
      painted_places[start + (dy + row) * width + dx + col] = byte & 0x0F;
      painted_places[start + (dy + row) * width + dx + col + 1] = byte >> 4;
    }
  }
  paint_run_images(run);
}

static function rg_screen_blit(image:Int, x:Int, y:Int):Void { blit_image(image, x, y); }

static function rg_screen_blit_pose(poses:Vector<Int>, count:Int, pose:Int, x:Int, y:Int):Void {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

/* --- what a feature reads of the screen --- */

static inline var RG_SOLID:Int = -1;
static inline var RG_SEE_THROUGH:Int = 0xFFFF;
static inline var RG_SIZE_REBUILT_WHOLE:Int = 3;
static inline var NOBODY_ASKED:Int = -1;

/* Whether the scenery was stamped onto the copy kept to put back under sprites (Reference @scenery_kept). */
static var scenery_kept:Int = 0;

static function rebuilt_whole():Int { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* What is painted from here on goes through the colour table a placed fade in force asks for it
 * (rg_hook_paint_fade_for), or as drawn where there is none. */
static var paint_fade:RgShownFilter = null;

static function fade_unless_left_as_drawn(fade_place:Int):Void { paint_fade = rg_hook_paint_fade_for(fade_place); }
static function fade_nothing():Void { paint_fade = null; }

/* Reference#placed_fade_in_picture?: a placed fade in force changes the backdrop, which is behind everything. */
static function placed_fade_in_picture():Bool { return rg_hook_paint_fade_for(RG_NO_LAYER) != null; }

/* Framebuffer#apply_placed_fade: a colour as it is painted while a placed fade reaches it. */
static function faded_as_painted(color:Int):Int {
  var masked = color & 0xFFFF;
  if (paint_fade == null) return masked;
  var faded = paint_fade.table[masked];
  return faded < 0 ? paint_fade.fill(masked) : faded;
}

/* --- see-through layers --- */

static function see_through_layers():Int { return rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; }
static function see_through_field(layer:Int, field:Int):Int { return rg_game_see_through[layer * RG_ST_FIELDS + field]; }

static var asked_layer:Int = NOBODY_ASKED;
static var answered_shows:Int = 0;
static var answered_behind:Int = 0;

static function rg_see_through_asked(layer:Int):Int { return layer == asked_layer ? 1 : 0; }

static function rg_see_through_answer(shows:Int, behind:Int):Void {
  answered_shows = shows;
  answered_behind = behind;
}

/* IR::SeeThrough.nearest_steps and .floor_steps: an amount is a game's number, so it is worked out as a float. */
static function held_to_sixteenths(sixteenths:Float):Int { return sixteenths < 0 ? 0 : (sixteenths > 16 ? 16 : Std.int(sixteenths)); }
static function nearest_sixteenths(amount:Int):Int { var whole:Float = amount; return held_to_sixteenths(rg_floor((whole * 16 + 50) / 100)); }
static function whole_sixteenths(amount:Int):Int { var whole:Float = amount; return held_to_sixteenths(rg_floor(whole * 16 / 100)); }

/* Reference#live_see_through_weights */
static function shares_now(layer:Int):RgShares {
  asked_layer = layer;
  rg_game_see_through_amounts();
  asked_layer = NOBODY_ASKED;
  var sign = see_through_field(layer, RG_ST_SUBTRACTS) != 0 ? -1 : 1;
  if (see_through_field(layer, RG_ST_ONE_AMOUNT) != 0) {
    var under = whole_sixteenths(answered_behind);
    return new RgShares(16 - under, sign * under);
  }
  return new RgShares(nearest_sixteenths(answered_shows), sign * nearest_sixteenths(answered_behind));
}

static var owed_shares:Array<RgKeptShares> = [for (i in 0...RG_MAX_SEE_THROUGH) new RgKeptShares()];
static var told_shares:Array<RgKeptShares> = [for (i in 0...RG_MAX_SEE_THROUGH) new RgKeptShares()];

/* Reference#layer_has_anything?: scenery showing now (rg_hook_layer_holds_scenery), or a sprite drawn in that layer. */
static function layer_holds_anything(layer:Int):Bool {
  return see_through_field(layer, RG_ST_HOLDS_A_SPRITE) != 0 || rg_hook_layer_holds_scenery(layer);
}

/* Reference#capture_see_through_weights */
static function keep_shares_for_owed_rebuild():Void {
  for (layer in 0...see_through_layers()) {
    owed_shares[layer].kept = see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) == 0 && layer_holds_anything(layer) ? 1 : 0;
    if (owed_shares[layer].kept != 0) owed_shares[layer].at = shares_now(layer);
  }
}

static function forget_kept_shares():Void {
  for (layer in 0...see_through_layers()) owed_shares[layer].kept = 0;
}

/* Reference#set_see_through_for, for scenery. A fade that holds the display's blend (rg_hook_blend_held_by_fade,
 * Reference#fading?) leaves the layer solid. */
static function mix_as_layer(layer:Int):Void {
  painting_sprite = 0;
  mixing = layer != RG_SOLID && !rg_hook_blend_held_by_fade() ? 1 : 0;
  if (mixing != 0) {
    mixed_by = owed_shares[layer].kept != 0 ? owed_shares[layer].at : shares_now(layer);
    mixed_cells_by = mixed_by;
  }
}

static function mix_nothing():Void {
  mixing = 0;
  painting_sprite = 0;
}

/* Reference#exec_see_through */
static function rg_see_through_told(layer:Int):Void {
  var now = shares_now(layer);
  var told = told_shares[layer];
  if (told.kept != 0 && told.at.painted == now.painted && told.at.under == now.under) return;
  told.kept = 1;
  told.at = now;
  request_repaint();
}

/* Framebuffer#paint_row, a cell at a time */
static function lay_scenery(px:Int, py:Int, color:Int):Void {
  var at = py * RG_SCREEN_WIDTH + px;
  pixels[at] = into_cell(color, pixels[at], pixels, at);
  if (sprites_seen_through() != 0) picture_without_sprites[at] = pixels[at];
}

/* A rebuild that request_repaint would have owed, left out because nothing moved. */
static function skip_repaint():Void {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0) return;
  rebuild_skipped = 1;
}

/* IR::Affine.matrix */
static function affine_matrix(angle:Int, size:Int):Array<Int> {
  var scale_one = rg_game_turn_rules[0];
  var one_th = rg_game_turn_rules[1];
  var most = rg_game_turn_rules[2];
  var least_size = rg_game_turn_rules[3];
  var scale = size < least_size ? least_size : size;
  var recip = Std.int((scale_one * 1.0 * one_th) / scale);
  if (recip > most) recip = most;
  return [rg_floor_div(rg_game_sines[angle + 90] * recip, one_th), rg_floor_div(rg_game_sines[angle] * recip, one_th)];
}

static inline function floor_mod(a:Int, b:Int):Int { return a - rg_floor_div(a, b) * b; }
static inline function clamp_number(value:Int, low:Int, high:Int):Int { return value < low ? low : (value > high ? high : value); }

/* What the game has painted (Reference @bitmaps, for the tiles and pictures of a run): where each run's places are
 * kept, the places of the tiles a game paints from its lists. */
static inline var RG_RUN_TILES:Int = 0;
static inline var RG_RUN_WIDTH:Int = 1;
static inline var RG_RUN_HEIGHT:Int = 2;
static inline var RG_RUN_PLACES:Int = 3;
static inline var RG_RUN_FIRST_IMAGE:Int = 4;
static inline var RG_RUN_IMAGES:Int = 5;
static inline var RG_RUN_PLANES:Int = 6;
static inline var RG_RUN_FIELDS:Int = 7;
static inline var RG_RUN_IMAGE_FIELDS:Int = 17;
static inline var RG_SIZE_BACKGROUNDS:Int = 0;
static inline var RG_SIZE_ALWAYS_UP:Int = 2;
static inline var RG_SIZE_RUNS:Int = 7;
static inline var RG_SIZE_RUN_PIXELS:Int = 8;
static inline var RUN_TILE_SIDE:Int = 8;
static inline var RUN_TILE_PIXELS:Int = 64;
static inline var PLACES_IN_RUN_COLORS:Int = 16;
static var painted_places:Vector<Int> = null;

static function run_field(run:Int, field:Int):Int { return rg_game_tile_runs[RG_RUN_FIELDS * run + field]; }

/* Where a run's places start in painted_places. */
static function places_of(run:Int):Int {
  if (painted_places == null) painted_places = new Vector<Int>(rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1);
  return run_field(run, RG_RUN_PLACES);
}

static function painted_places_at(at:Int):Int { return painted_places[at]; }

/* Reference#request_repaint (rg_hook_repaint_requested is where a feature hears of it) */
static function request_repaint():Void {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0) return;
  rg_hook_repaint_requested();
  owed = 1;
  keep_shares_for_owed_rebuild();
}

static function rg_screen_request_rebuild():Void { request_repaint(); }

/* Reference#painted_screen? */
static function painted_screen():Bool { return kind < 0 || kind == RG_BITMAP; }

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

/* Back to front: the backdrop, then each level's scenery and sprites (rg_hook_paint_level, scenery first),
 * with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending). */
static function repaint_view():Void {
  repaints_painted++;
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(backdrop);
  rg_hook_repaint_began();
  var levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (level in 0...levels) rg_hook_paint_level(level);
  rg_hook_repaint_ending();
  mix_nothing();
  fade_nothing();
  picture_touched = 0;
}

/* Reference#paint_owed_repaint */
static function rg_screen_paint_owed_rebuild():Void {
  var skipped_and_touched = rebuild_skipped != 0 && picture_touched != 0;
  rebuild_skipped = 0;
  if (owed != 0 || skipped_and_touched) {
    owed = 0;
    repaint_view();
    forget_kept_shares();
  }
  rg_hook_rebuild_checked();
}

/* --- screens and scenes --- */

static function rg_screen_hold(value:Int):Void { held = value; }

/* Whether the end of a pass is placing the frame's writes (Reference @placing_at_pass_end). */
static var placing_at_pass_end:Int = 0;

static function rg_screen_placing_at_pass_end(on:Int):Void {
  placing_at_pass_end = on;
}

static function rg_screen_frame_started():Void {
  held = 0;
  frames_begun = 1;
}

/* The top of Reference#advance_frame: a tear-free screen trades its pages. */
static function rg_screen_frame_ended():Void {
  rg_hook_frame_ended();
  if (pixels == viewed) return;
  rg_screen_paint_owed_rebuild();
  var finished = pixels;
  pixels = viewed;
  viewed = finished;
  target = pixels;
  picture_touched = 1; // the page handed over was built before the one just shown
  rg_game_sprites_over_picture(); // Reference#advance_frame: placed with the page published
}

/* rg_screen.c's show_backdrop */
static function show_backdrop(color:Int):Void {
  if (color < 0 || color == backdrop) return;
  backdrop = color;
  scenery_kept = 0;
  if (rg_hook_scenery_up()) request_repaint();
  else clear_to(backdrop);
}

/* Reference#exec_screen */
static function rg_screen_set(new_kind:Int, two_pages:Int, new_backdrop:Int):Int {
  var crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    if (new_backdrop >= 0) backdrop = new_backdrop;
    clear_to(backdrop);
    scenery_kept = 0;
  } else {
    show_backdrop(new_backdrop);
  }
  kind = new_kind;
  show_pages(two_pages);
  rg_hook_screen_set(); // a tint in force is mixed this screen's way
  if (!crossing) return 0;
  rg_hook_screen_crossed(new_kind);
  return new_kind != RG_BITMAP ? 1 : 0;
}

/* Reference#cross_to_scene_screen */
static function rg_screen_cross_to(new_kind:Int, two_pages:Int, new_backdrop:Int):Int {
  if (kind >= 0 && kind != new_kind) return rg_screen_set(new_kind, two_pages, new_backdrop);
  show_backdrop(new_backdrop);
  return 0;
}

static function rg_screen_show_backdrop(color:Int):Void { show_backdrop(color); }

static function rg_scene_enter(scene:Int):Void { current_scene = scene; }

/* Whether the last scene to take over took any scenery down. */
static var scenery_taken_down:Int = 0;

/* The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes down. */
static function rg_scene_take_down(brings_scenery:Int):Void { scenery_taken_down = rg_hook_scene_take_down(brings_scenery) ? 1 : 0; }

/* Reference#redraw_sprites_over_arrived_scenery */
static function rg_scene_redraw_sprites(brings_scenery:Int):Void {
  if (brings_scenery == 0 && scenery_taken_down == 0) return;
  if (painted_screen() || !rg_hook_any_sprite_kept()) return;
  request_repaint();
}

/* Reference#sprites: what the game last put on screen. The headless runners read it for every game, so it
 * answers through the hooks: none for a game with no sprites. */
static function rg_screen_drawn_count():Int { return rg_hook_drawn_count(); }
static function rg_screen_drawn_sprite(place:Int):RgDrawnSprite { return rg_hook_drawn_sprite(place); }

/* --- reading it back --- */

static function rg_screen_two_pages():Int { return pixels != viewed ? 1 : 0; }

static function rg_screen_repaints_painted():Int { return repaints_painted; }
static function rg_screen_drawn_tiles_set_up():Int { return 0; }

/* Framebuffer#to_a */
static function rg_screen_stored():Vector<Int> {
  rg_screen_paint_owed_rebuild();
  return viewed;
}

/* Framebuffer#displayed: the picture as a console that keeps fewer than five bits of a channel shows it,
 * each channel's top bits repeated to widen it back to five. */
static function keep_console_colors():Void {
  if (RG_COLOR_BITS >= 5) return;
  var lost = 5 - RG_COLOR_BITS;
  var kept_mask = (1 << RG_COLOR_BITS) - 1;
  for (at in 0...RG_CELLS) {
    var kept = 0;
    var channel = 0;
    while (channel <= 10) {
      var level = (shown[at] >> (channel + lost)) & kept_mask;
      kept |= ((level << lost) | (level >> (RG_COLOR_BITS - lost))) << channel;
      channel += 5;
    }
    shown[at] = kept;
  }
}

/* Does the filter's row say it changes the pixel at column +x+? A filter's rows are flat, three numbers a
 * screen row [from, to, inverted]: a pixel is changed when inverted XOR from <= x < to. */
static function filter_row_covers(rows:Vector<Int>, row:Int, x:Int):Bool { return (rows[row + 2] != 0) != (x >= rows[row] && x < rows[row + 1]); }

/* Framebuffer#shown and #pixel: each pixel read from where a feature says it is read from
 * (rg_hook_shown_columns, rg_hook_shown_row), or its own place, with the layer a feature shows in front of
 * the picture laid over it (rg_hook_front_layer, asked once a read), then through the fade or tint and the
 * light where those reach it, and white for a held display. */
static inline var RG_NOTHING_IN_FRONT:Int = 0x8000;

static function rg_screen_shown():Vector<Int> {
  rg_screen_paint_owed_rebuild();
  var columns = rg_hook_shown_columns();
  var front = rg_hook_front_layer();
  var fade = rg_hook_fade_filter();
  var dim = rg_hook_dim_filter();
  for (y in 0...RG_SCREEN_HEIGHT) {
    var from_y = rg_hook_shown_row(y) + camera_y;
    var fade_covers = fade != null && !fade.everywhere;
    var dim_covers = dim != null && !dim.everywhere;
    for (x in 0...RG_SCREEN_WIDTH) {
      var fade_here = fade != null && (!fade_covers || filter_row_covers(fade.rows, y * 3, x));
      var in_front = front != null ? front[y * RG_SCREEN_WIDTH + x] : RG_NOTHING_IN_FRONT;
      var color:Int;
      if (in_front != RG_NOTHING_IN_FRONT) {
        // a sprite over the picture is not in blocks
        color = in_front;
        if (fade_here) {
          color = fade.table[in_front];
          if (color < 0) color = fade.fill(in_front);
        }
      } else {
        var from_x = (columns != null ? columns[x] : x) + camera_x;
        var at = from_y * RG_SCREEN_WIDTH + from_x;
        var stored = on_screen(from_x, from_y) ? viewed[at] : 0;
        if (fade != null && fade.remix && on_screen(from_x, from_y) && picture_mixes.is_mixed[at] != 0) {
          // Framebuffer#shown_color: a mixed cell is mixed again from its two sides, each through the table
          var top = fade.table[picture_mixes.tops[at]];
          if (top < 0) top = fade.fill(picture_mixes.tops[at]);
          var under = fade.table[picture_mixes.unders[at]];
          if (under < 0) under = fade.fill(picture_mixes.unders[at]);
          color = mixed_with_under(top, under, mixed_cells_by);
        } else {
          color = stored;
          if (fade_here) {
            color = fade.table[stored];
            if (color < 0) color = fade.fill(stored);
          }
        }
      }
      if (dim != null && (!dim_covers || filter_row_covers(dim.rows, y * 3, x))) {
        var dimmed = dim.table[color];
        color = dimmed < 0 ? dim.fill(color) : dimmed;
      }
      shown[y * RG_SCREEN_WIDTH + x] = held != 0 ? 0x7FFF : color;
    }
  }
  black_rows_given_up();
  keep_console_colors();
  return shown;
}

/* The picture as the window shows it, the whole screen. Where the game's screen is shown in a border, the
 * border with the picture as shown over its middle. */
static var rg_screen_bordered:Bool = RG_WHOLE_WIDTH != RG_SCREEN_WIDTH || RG_WHOLE_HEIGHT != RG_SCREEN_HEIGHT;
static var framed:Vector<Int> = null;
static function rg_screen_framed():Vector<Int> { return rg_screen_framed_from(rg_screen_shown()); }

/* The same, from a picture as it was shown. */
static function rg_screen_framed_from(game:Vector<Int>):Vector<Int> {
  if (!rg_screen_bordered) return framed_scene_screen(game);
  if (framed == null) {
    framed = new Vector<Int>(RG_WHOLE_WIDTH * RG_WHOLE_HEIGHT);
    for (at in 0...framed.length) framed[at] = rg_game_border_pixels[at];
  }
  for (y in 0...RG_SCREEN_HEIGHT) {
    for (x in 0...RG_SCREEN_WIDTH) framed[(y + RG_GAME_TOP) * RG_WHOLE_WIDTH + RG_GAME_LEFT + x] = game[y * RG_SCREEN_WIDTH + x];
  }
  return framed;
}

/* The picture for a scene's smaller screen: the top left of +picture+, at its own size in the middle of the
 * window and black round it. The picture as it is where it is all shown. */
static var scene_framed:Vector<Int> = null;
static function framed_scene_screen(picture:Vector<Int>):Vector<Int> {
  if (shown_width >= RG_SCREEN_WIDTH && shown_height >= RG_SCREEN_HEIGHT) return picture;
  if (scene_framed == null) scene_framed = new Vector<Int>(RG_CELLS);
  for (at in 0...RG_CELLS) scene_framed[at] = 0;
  var left = (RG_SCREEN_WIDTH - shown_width) >> 1;
  var top = (RG_SCREEN_HEIGHT - shown_height) >> 1;
  for (y in 0...shown_height) {
    for (x in 0...shown_width) scene_framed[(y + top) * RG_SCREEN_WIDTH + left + x] = picture[y * RG_SCREEN_WIDTH + x];
  }
  return scene_framed;
}

/* The rows the game gave up (`shown_rows:`) black. */
static function black_rows_given_up():Void {
  if (held != 0) return;
  for (y in 0...RG_SCREEN_HEIGHT) {
    if (y < RG_SHOWN_FIRST_ROW || y >= RG_SHOWN_PAST_ROW) {
      for (x in 0...RG_SCREEN_WIDTH) shown[y * RG_SCREEN_WIDTH + x] = 0;
    }
  }
}

/* --- the picture's check number --- */

static var rg_crc_table:Vector<Int> = null;
static function rg_crc_table_made():Vector<Int> {
  if (rg_crc_table != null) return rg_crc_table;
  rg_crc_table = new Vector<Int>(256);
  for (n in 0...256) {
    var c = n;
    for (bit in 0...8) c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    rg_crc_table[n] = c;
  }
  return rg_crc_table;
}

/* The CRC-32 zip files use, which Ruby's Zlib.crc32 works out from the same bytes. */
static function rg_picture_crc(pixels:Vector<Int>):String {
  var table = rg_crc_table_made();
  var crc = -1;
  for (i in 0...RG_CELLS) {
    var pixel = pixels[i];
    crc = table[(crc ^ pixel) & 0xFF] ^ (crc >>> 8);
    crc = table[(crc ^ (pixel >> 8)) & 0xFF] ^ (crc >>> 8);
  }
  return StringTools.hex(crc ^ -1, 8).toLowerCase();
}

