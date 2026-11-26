/*
 * The game's picture, drawn in software: the console's screen as an array of colors, and everything the
 * game does to it. A port of the JavaScript runtime's rg_screen.js, which is itself a port of the
 * interpreter's picture (backends/reference.rb and reference/framebuffer.rb) — each function names the
 * interpreter's method it follows, because that is what decides what is right here.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest.
 *
 * What it does not draw yet: see-through layers, fades and tints, tiled backgrounds, sprites, poses,
 * pixelation and light — the features, which a game that needs one is refused for by name — and
 * pictures blitted whole.
 */

static inline var RG_CELLS:Int = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;

static inline var RG_BITMAP:Int = 0;
static inline var RG_TILED:Int = 1;
static inline var RG_ROTOZOOM:Int = 2;

static inline var RG_NO_LAYER:Int = -1;
static inline var RG_SIZE_DEPTHS:Int = 1;
static inline var RG_SIZE_SCREEN_KINDS_CHANGE:Int = 5;

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

/* --- the picture itself (Framebuffer) --- */

static inline function on_screen(x:Int, y:Int):Bool { return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT; }

static function paintable(x:Int, y:Int):Bool {
  if (!on_screen(x, y)) return false;
  return area_in_force == 0 || (x >= area_left && x < area_right && y >= area_top && y < area_bottom);
}

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. */
static function set_pixel(x:Int, y:Int, color:Int):Void {
  if (!paintable(x, y)) return;
  picture_touched = 1;
  pixels[y * RG_SCREEN_WIDTH + x] = color & 0xFFFF;
}

/* Framebuffer#fill_rect */
static function fill_cells(x:Int, y:Int, width:Int, height:Int, color:Int):Void {
  var left = x < 0 ? 0 : x;
  var top = y < 0 ? 0 : y;
  var right = x + width;
  var bottom = y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
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
  var painted = color & 0xFFFF;
  for (at in 0...RG_CELLS) pixels[at] = painted;
}

static function rg_screen_clear(color:Int):Void { clear_to(color); }
static function rg_screen_fill_rect(x:Int, y:Int, width:Int, height:Int, color:Int):Void { fill_cells(x, y, width, height, color); }

static function rg_screen_inside(x:Int, y:Int, width:Int, height:Int):Void {
  if (outer_areas.length >= AREAS_DEEP) rg_fault("more than " + AREAS_DEEP + " `inside` blocks are open at once");
  outer_areas.push([area_in_force, area_left, area_top, area_right, area_bottom]);
  area_in_force = 1;
  area_left = x;
  area_top = y;
  area_right = x + width;
  area_bottom = y + height;
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
  var start = rg_game_images[info];
  var width = rg_game_images[info + 1];
  var height = rg_game_images[info + 2];
  var colors = rg_game_images[info + 3];
  for (row in 0...height) {
    for (col in 0...width) {
      var held = rg_game_image_pixels[start + row * width + col];
      if (held == RG_NOT_DRAWN) continue;
      set_pixel(x + col, y + row, colors == RG_NO_IMAGE_COLORS ? held : rg_game_image_pixels[colors + held]);
    }
  }
}

static function rg_screen_blit(image:Int, x:Int, y:Int):Void { blit_image(image, x, y); }

static function rg_screen_blit_pose(poses:Vector<Int>, count:Int, pose:Int, x:Int, y:Int):Void {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

/* Reference#request_repaint (rg_hook_repaint_requested is where a feature hears of it) */
static function request_repaint():Void {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0) return;
  rg_hook_repaint_requested();
  owed = 1;
}

static function rg_screen_request_rebuild():Void { request_repaint(); }

/* Reference#painted_screen? */
static function painted_screen():Bool { return kind < 0 || kind == RG_BITMAP; }

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

/* Back to front: the backdrop, then each level's scenery and sprites (rg_hook_paint_level, scenery first),
 * with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending). */
static function repaint_view():Void {
  repaints_painted++;
  clear_to(backdrop);
  rg_hook_repaint_began();
  var levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (level in 0...levels) rg_hook_paint_level(level);
  rg_hook_repaint_ending();
  picture_touched = 0;
}

/* Reference#paint_owed_repaint */
static function rg_screen_paint_owed_rebuild():Void {
  var skipped_and_touched = rebuild_skipped != 0 && picture_touched != 0;
  rebuild_skipped = 0;
  if (owed != 0 || skipped_and_touched) {
    owed = 0;
    repaint_view();
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
  picture_touched = 1; // the page handed over was built before the one just shown
  rg_game_sprites_over_picture(); // Reference#advance_frame: placed with the page published
}

/* rg_screen.c's show_backdrop */
static function show_backdrop(color:Int):Void {
  if (color < 0 || color == backdrop) return;
  backdrop = color;
  if (rg_hook_scenery_up()) request_repaint();
  else clear_to(backdrop);
}

/* Reference#exec_screen */
static function rg_screen_set(new_kind:Int, two_pages:Int, new_backdrop:Int):Int {
  var crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    if (new_backdrop >= 0) backdrop = new_backdrop;
    clear_to(backdrop);
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
        color = stored;
        if (fade_here) {
          color = fade.table[stored];
          if (color < 0) color = fade.fill(stored);
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
static function rg_screen_framed():Vector<Int> {
  if (!rg_screen_bordered) return framed_scene_screen(rg_screen_shown());
  if (framed == null) {
    framed = new Vector<Int>(RG_WHOLE_WIDTH * RG_WHOLE_HEIGHT);
    for (at in 0...framed.length) framed[at] = rg_game_border_pixels[at];
  }
  var game = rg_screen_shown();
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

