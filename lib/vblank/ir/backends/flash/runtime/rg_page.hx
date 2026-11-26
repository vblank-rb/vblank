/*
 * The runtime that plays a game on a stage: what a person plays (the JavaScript runtime's rg_page.js, for a
 * Flash player).
 *
 * The picture is one opaque BitmapData the size of the console's whole screen, painted by this runtime and
 * shown through a Bitmap scaled by a whole number (RG_PAGE_SCALE) with smoothing off, so a pixel stays a
 * square. The keyboard is the gamepad: RG_KEYS says which key is which button of which player (the same
 * keys the web page's are, Flash::Lowering#keys_text). The runtime keeps its own time with getTimer() and on
 * each ENTER_FRAME plays as many passes as are due, so the game runs at the console's speed whatever rate
 * the movie is woken at.
 *
 * Built with the define rg_trace_pictures, it traces the picture's check number each time it paints (Flash#build_swf's
 * trace_pictures), which is how a test sees what the stage would show.
 *
 * What it does not do yet: sound, a menu, a gamepad. Left out of the movie, a game that needs one is
 * refused by name before it is built (Flash#runtime_gaps).
 */

/* The most passes one ENTER_FRAME plays to catch up, so a stall does not turn into a long run of them. */
static inline var PAGE_MOST_PASSES:Int = 4;

static var page_bitmap:flash.display.BitmapData = null;
static var page_colors:Vector<Int> = null;
static var page_keys_down:Array<Int> = [];
static var page_started_at:Int = 0;
static var page_passes:Int = 0;
static var page_stopped:Bool = false;
static var page_shared:flash.net.SharedObject = null;

/* The 15-bit colours as the opaque 24-bit ones the picture shows, each channel widened by repeating its top
 * bits underneath ((c << 3) | (c >> 2)), so the brightest is 255 and not 248. */
static function page_colors_table():Vector<Int> {
  if (page_colors != null) return page_colors;
  page_colors = new Vector<Int>(32768);
  for (color in 0...32768) {
    var red = color & 0x1F;
    var green = (color >> 5) & 0x1F;
    var blue = (color >> 10) & 0x1F;
    page_colors[color] = (((red << 3) | (red >> 2)) << 16) | (((green << 3) | (green >> 2)) << 8) | ((blue << 3) | (blue >> 2));
  }
  return page_colors;
}

/* The picture, painted: the whole screen as the window shows it. */
static function page_paint():Void {
  var whole = rg_screen_framed();
  var colors = page_colors_table();
  page_bitmap.lock();
  for (y in 0...RG_WHOLE_HEIGHT) {
    for (x in 0...RG_WHOLE_WIDTH) page_bitmap.setPixel(x, y, colors[whole[y * RG_WHOLE_WIDTH + x] & 0x7FFF]);
  }
  page_bitmap.unlock();
  #if rg_trace_pictures
  flash.Lib.trace("picture-crc " + rg_picture_crc(rg_screen_shown()));
  #end
}

/* The buttons each player holds now: a number each, a bit a button, from the keys that are down. */
static function page_masks():Array<Int> {
  var masks:Array<Int> = [for (player in 0...RG_MOST_PLAYERS) 0];
  var entry = 0;
  while (entry < RG_KEYS.length) {
    if (page_keys_down.indexOf(RG_KEYS[entry] * 4 + RG_KEYS[entry + 1]) >= 0) masks[RG_KEYS[entry + 2]] |= 1 << RG_KEYS[entry + 3];
    entry += 4;
  }
  return masks;
}

/* A key pressed or let go. A key is kept by its code and which side it is on: a right shift is not a left. */
static function page_key(event:flash.events.KeyboardEvent, down:Bool):Void {
  var side = cast(event.keyLocation, Int) == 2 ? 2 : 0;
  var wanted = [event.keyCode * 4 + side, event.keyCode * 4];
  for (key in wanted) {
    var at = page_keys_down.indexOf(key);
    if (down && at < 0) page_keys_down.push(key);
    if (!down && at >= 0) page_keys_down.splice(at, 1);
  }
}

/* One frame of the game, from where it stopped to its next frame boundary, painted. */
static function page_play_pass():Void {
  var now = Date.now();
  rg_clock_reads(now.getFullYear(), now.getMonth() + 1, now.getDate(), now.getHours(), now.getMinutes(), now.getSeconds());
  rg_players_read(page_masks());
  while (true) {
    if (rg_game_pass() == 0) {
      page_stopped = true;
      return;
    }
    if (rg_frame_ends_late() != 0) {
      rg_frame_begins();
      page_paint();
      page_store_saves();
      return;
    }
    if (rg_frame_begins() == 0) {
      page_paint();
      page_store_saves();
      return;
    }
  }
}

static function page_on_frame(_:flash.events.Event):Void {
  if (page_stopped) return;
  var due = Std.int((flash.Lib.getTimer() - page_started_at) * RG_CONSOLE_TICKS_A_SECOND / (1000.0 * RG_CONSOLE_TICKS_A_FRAME));
  var played = 0;
  try {
    while (page_passes < due && played < PAGE_MOST_PASSES && !page_stopped) {
      page_play_pass();
      page_passes++;
      played++;
    }
  } catch (stopped:RgStopped) {
    page_stopped = true;
    if (stopped.wentWrong) flash.Lib.trace(stopped.message);
  } catch (error:Dynamic) {
    page_stopped = true;
    flash.Lib.trace(Std.string(error));
  }
  if (played == PAGE_MOST_PASSES) page_passes = due; // too far behind to catch up
}

/* The save memory is kept in a SharedObject of the game's own (named by the digest of the build), as hex digits,
 * written when the game has changed it and been quiet a moment (rg_save_file_is_due). */
static function page_keep_saves():Void {
  if (rg_save_size() == 0) return;
  page_shared = flash.net.SharedObject.getLocal("vblank-" + RG_GAME_BUILD.substr(0, 24));
  if (Std.isOfType(page_shared.data.save, String)) rg_save_load_hex(page_shared.data.save);
}

static function page_store_saves():Void {
  if (page_shared == null || rg_save_file_is_due() == 0) return;
  page_shared.data.save = rg_save_hex();
  page_shared.flush();
  rg_save_file_written();
  #if rg_trace_pictures
  flash.Lib.trace("saved " + page_shared.data.save);
  #end
}

/* The driver's part of what the game asks of its runtime: a page prints nothing. */
static function rg_sound_logged(line:String):Void {}
static function headless_print(text:String):Void {}
static function rg_dump_variable(name:String, value:Int):Void {}
static function rg_dump_list(list:RgList):Void {}

static function main():Void {
  var stage = flash.Lib.current.stage;
  stage.scaleMode = flash.display.StageScaleMode.NO_SCALE;
  stage.align = flash.display.StageAlign.TOP_LEFT;
  page_bitmap = new flash.display.BitmapData(RG_WHOLE_WIDTH, RG_WHOLE_HEIGHT, false, 0);
  var bitmap = new flash.display.Bitmap(page_bitmap, flash.display.PixelSnapping.ALWAYS, false);
  bitmap.scaleX = RG_PAGE_SCALE;
  bitmap.scaleY = RG_PAGE_SCALE;
  flash.Lib.current.addChild(bitmap);
  stage.addEventListener(flash.events.KeyboardEvent.KEY_DOWN, function(event:flash.events.KeyboardEvent) { page_key(event, true); });
  stage.addEventListener(flash.events.KeyboardEvent.KEY_UP, function(event:flash.events.KeyboardEvent) { page_key(event, false); });
  page_keep_saves();
  page_started_at = flash.Lib.getTimer();
  stage.addEventListener(flash.events.Event.ENTER_FRAME, page_on_frame);
}
