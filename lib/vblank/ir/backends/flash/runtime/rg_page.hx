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
 * The sound is the game's own, made where each frame ends (rg_sound_render_frame) and played through a Sound the player
 * asks for samples (see the sound's section below).
 *
 * Built with the define rg_trace_pictures, it traces the picture's check number each time it paints (Flash#build_swf's
 * trace_pictures), which is how a test sees what the stage would show. Built with rg_trace_sound, it traces the check
 * number of each frame's sound and what the sound device would be given, and takes the device's samples itself, a frame's
 * worth after each pass the game plays, for the harness has no device to ask (and its Ruffle sends no sampleData events at
 * all).
 *
 * What it does not do yet: a menu, a gamepad.
 */

/* The most passes one ENTER_FRAME plays to catch up, so a stall does not turn into a long run of them. */
static inline var PAGE_MOST_PASSES:Int = 4;

/* The sound device's rate: a Sound that is made as it plays always plays at this, and asks for at least PAGE_SOUND_ASKED
 * samples a time (fewer ends the sound). */
static inline var PAGE_DEVICE_RATE:Int = 44100;
static inline var PAGE_SOUND_ASKED:Int = 2048;
static inline var PAGE_RING_SIZE:Int = 96000; // two seconds of the game's samples

static var page_bitmap:flash.display.BitmapData = null;
static var page_colors:Vector<Int> = null;
static var page_keys_down:Array<Int> = [];
static var page_started_at:Int = 0;
static var page_passes:Int = 0;
static var page_stopped:Bool = false;
static var page_shared:flash.net.SharedObject = null;
static var page_left:Vector<Int> = new Vector<Int>(RG_SOUND_FRAME_MOST);
static var page_right:Vector<Int> = new Vector<Int>(RG_SOUND_FRAME_MOST);
static var page_ring_left:Vector<Float> = new Vector<Float>(PAGE_RING_SIZE);
static var page_ring_right:Vector<Float> = new Vector<Float>(PAGE_RING_SIZE);
static var page_written:Float = 0; // the game's samples taken in, ever
static var page_read:Float = 0; // how far through them the device has got: a fraction, the game's samples being read in between
static var page_priming:Bool = true; // waiting for a little sound to be ready before playing
static var page_sound_held_up:Bool = false;
static var page_heard:Vector<Float> = new Vector<Float>(PAGE_SOUND_ASKED * 2);

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

/* --- the sound ---
 *
 * The frame's sound is made where the frame ends, at the game's own rate (RG_SOUND_RATE), and kept in a ring. The device
 * asks for samples at its own rate and each it is given is read from between two of the game's, which plays the sound at
 * the right pitch whatever the device runs at. A device that ran dry waits for a little sound to be ready before it starts
 * again, and one with more waiting than it should have lets the oldest go, so the sound never falls far behind the game
 * (rg_page.js's worklet does the same). */

/* The frame's sound, taken in after the frame before's. */
static function page_play_sound():Void {
  var count = rg_sound_render_frame(page_left, page_right);
  if (count == 0) return;
  var at = Std.int(page_written % PAGE_RING_SIZE);
  for (i in 0...count) {
    page_ring_left[at] = page_left[i] / 32768.0;
    page_ring_right[at] = page_right[i] / 32768.0;
    at++;
    if (at == PAGE_RING_SIZE) at = 0;
  }
  page_written += count;
  if (page_written - page_read > RG_SOUND_RATE * 0.25) page_read = page_written - RG_SOUND_RATE * 0.05;
  #if rg_trace_sound
  page_trace_frame_sound(count);
  #end
}

/* +count+ samples for the device, a left and a right one each, in +into+ (twice as many numbers). */
static function page_sound_heard(count:Int, into:Vector<Float>):Void {
  var step:Float = RG_SOUND_RATE / PAGE_DEVICE_RATE; // the game's samples used up for each one the device is given
  for (i in 0...count) {
    var waiting = page_written - page_read;
    if (page_priming && waiting >= RG_SOUND_RATE * 0.05) page_priming = false;
    if (page_priming || waiting < 2) {
      page_priming = true;
      into[i * 2] = 0;
      into[i * 2 + 1] = 0;
      continue;
    }
    var first = rg_floor(page_read);
    var share = page_read - first;
    var a = Std.int(first % PAGE_RING_SIZE);
    var b = Std.int((first + 1) % PAGE_RING_SIZE);
    into[i * 2] = page_ring_left[a] + (page_ring_left[b] - page_ring_left[a]) * share;
    into[i * 2 + 1] = page_ring_right[a] + (page_ring_right[b] - page_ring_right[a]) * share;
    page_read += step;
  }
}

static function page_sound_asked(event:flash.events.SampleDataEvent):Void {
  page_sound_heard(PAGE_SOUND_ASKED, page_heard);
  for (i in 0...PAGE_SOUND_ASKED * 2) event.data.writeFloat(page_heard[i]);
}

#if rg_trace_sound
/* The check number of the frame's sound (the left and right sample in turn, each as the 16 bits a file keeps it in, low
 * byte first), and the loudest sample the device was given for the frame that has just been played (what a device would
 * ask for in the 1/60 of a second). */
static function page_trace_frame_sound(count:Int):Void {
  var table = rg_crc_table_made();
  var crc = -1;
  for (i in 0...count) {
    for (sample in [page_left[i], page_right[i]]) {
      crc = table[(crc ^ sample) & 0xFF] ^ (crc >>> 8);
      crc = table[(crc ^ (sample >> 8)) & 0xFF] ^ (crc >>> 8);
    }
  }
  flash.Lib.trace("sound-frame " + count + " " + StringTools.hex(crc ^ -1, 8).toLowerCase());
}

static function page_trace_device_heard():Void {
  var asked = Std.int(PAGE_DEVICE_RATE / 60);
  page_sound_heard(asked, page_heard);
  var loudest:Float = 0;
  for (i in 0...asked * 2) {
    var size = page_heard[i] < 0 ? -page_heard[i] : page_heard[i];
    if (size > loudest) loudest = size;
  }
  flash.Lib.trace("sound-heard " + Std.int(loudest * 32768));
}
#end

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
      page_play_sound();
      rg_frame_begins();
      page_paint();
      page_store_saves();
      return;
    }
    if (!page_sound_held_up) page_play_sound();
    var held_up = rg_frame_begins();
    page_sound_held_up = held_up != 0;
    if (held_up == 0) {
      page_paint();
      page_store_saves();
      return;
    }
  }
}

static function page_on_frame(_:flash.events.Event):Void {
  if (page_stopped) return;
  var elapsed:Float = flash.Lib.getTimer() - page_started_at; // a float: the milliseconds times the console's clock pass 32 bits in a tenth of a second
  var due = Std.int(elapsed * RG_CONSOLE_TICKS_A_SECOND / (1000.0 * RG_CONSOLE_TICKS_A_FRAME));
  var played = 0;
  try {
    while (page_passes < due && played < PAGE_MOST_PASSES && !page_stopped) {
      page_play_pass();
      #if rg_trace_sound
      page_trace_device_heard();
      #end
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
  var sound = new flash.media.Sound();
  sound.addEventListener(flash.events.SampleDataEvent.SAMPLE_DATA, page_sound_asked);
  sound.play();
  page_started_at = flash.Lib.getTimer();
  stage.addEventListener(flash.events.Event.ENTER_FRAME, page_on_frame);
}
