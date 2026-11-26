/*
 * The runtime with no window: what the tests run a game against, in the Flash player's harness
 * (ruby-flash-player/).
 *
 * It is the JavaScript runtime's rg_headless.js, saying the same thing in the same words, so one Ruby
 * reader drives either (Computer::HeadlessRun): it plays frames frames and stops at the start of the next,
 * and at every frame boundary traces "frame N", every variable ("var name value"), every list ("list name",
 * a tab, its items), every sprite last drawn ("sprite" and four numbers), where the window sits ("camera
 * X Y"), the picture's check number ("picture-crc"), and then "buttons?". The harness answers that with the
 * next frame's buttons (rg_buttons) before the next frame is played. At the end it traces "end" and the
 * same again, how many times the whole view was built again ("repaints"), and how many pages the screen
 * has, and asks the harness to stop (fscommand).
 *
 * It talks to the harness through ExternalInterface: the harness calls rg_start with the options (as the
 * C runtime's command line has them: --every-picture, --held-from-power-on MASK, --picture-out FILE, the
 * last the harness's own), rg_buttons with each frame's buttons, and rg_picture for the picture as the
 * harness's file holds it, and rg_save_hex for the save memory the harness's file holds when the game ends. rg_start is given one string: the frames to play, then each option on a line of its own. Each frame is one ENTER_FRAME: it plays the game from where it stopped to its
 * next frame boundary.
 *
 * Left out of what rg_headless.js does: the start file and matches. The run that asks for one says so before it starts (Flash::HeadlessRun).
 */

static var headless_frames_to_play:Int = 0;
static var headless_frame:Int = 0;
static var headless_every_picture:Bool = false;
static var headless_started:Bool = false;
static var headless_sound_out:Bool = false;
static var headless_left:Vector<Int> = new Vector<Int>(RG_SOUND_FRAME_MOST);
static var headless_right:Vector<Int> = new Vector<Int>(RG_SOUND_FRAME_MOST);
static var headless_hex_bytes:Array<String> = null;
static var headless_waiting_for_buttons:Bool = false;
static var headless_over:Bool = false;
static var headless_sound_held_up:Int = 0;
static var headless_state_out:Bool = false; /* the state is written (the harness keeps it in the file it was given)... */
static var headless_state_out_after:Int = -1; /* ...at the boundary after this frame */
static var headless_state_in:String = null; /* the state read in at the first boundary, until it is */

/* The picture as the last moment showed it. */
static var headless_shown_now:Vector<Int> = new Vector<Int>(RG_CELLS);

static function headless_print(text:String):Void { flash.Lib.trace(text); }

/* The harness's way of ending the run: the code it exits with, and a sentence for a game that went wrong. */
static function headless_exit(code:Int, message:String):Void {
  headless_over = true;
  flash.Lib.fscommand("rg_exit", code + ":" + message);
}

/* --- the picture, as numbers --- */

static function headless_print_pixels(word:String, pixels:Vector<Int>):Void {
  var hexes = new StringBuf();
  for (i in 0...pixels.length) hexes.add(StringTools.hex(pixels[i], 4).toLowerCase());
  headless_print(word + " " + hexes.toString());
}

/* The picture as the harness writes it to its file: every pixel as shown, then every pixel as stored (and the
 * whole screen where the game is shown in a border or has a screen of its own), each as a character of the
 * string whose number is the pixel, so the harness can write it two bytes a pixel, low byte first. The
 * characters are joined once at the end: adding them to a string one at a time copies the string each time. */
static function headless_add_pixels(parts:Array<String>, pixels:Vector<Int>, count:Int):Void {
  for (i in 0...count) parts.push(String.fromCharCode(pixels[i]));
}

static function headless_picture_string():String {
  var parts:Array<String> = [];
  // The picture as shown is the one the moment printed, read before anything owed was painted, then the stored one,
  // as rg_headless.js writes them.
  headless_add_pixels(parts, headless_shown_now, RG_CELLS);
  headless_add_pixels(parts, rg_screen_stored(), RG_CELLS);
  if (rg_screen_bordered || RG_SCREEN_OF_ITS_OWN != 0) {
    var whole = rg_screen_framed_from(headless_shown_now);
    headless_add_pixels(parts, whole, whole.length);
  }
  return parts.join("");
}

static function headless_print_sprites():Void {
  for (place in 0...rg_screen_drawn_count()) {
    var drawn = rg_screen_drawn_sprite(place);
    headless_print("sprite " + drawn.name + " " + drawn.picture + " " + drawn.x + " " + drawn.y);
  }
}

static function headless_print_moment(heading:String, with_picture:Bool):Void {
  headless_print(heading);
  rg_game_dump_state();
  headless_print_sprites();
  rg_hook_moment_printed(); /* each sound feature's own lines (the mixer's), none for a game without */
  headless_print("camera " + rg_screen_camera_x() + " " + rg_screen_camera_y());
  headless_print("motor " + rg_motor_on());
  var shown_pixels = rg_screen_shown();
  for (i in 0...RG_CELLS) headless_shown_now[i] = shown_pixels[i];
  if (with_picture) headless_print_pixels("picture", shown_pixels);
  else headless_print("picture-crc " + rg_picture_crc(shown_pixels));
}

/* The game stops being played: the end's moment and what is counted over the whole run. */
static function headless_finish():Void {
  if (headless_over) return;
  headless_print_moment("end", headless_every_picture);
  if (headless_every_picture) headless_print_pixels("stored", rg_screen_stored());
  headless_print("repaints " + rg_screen_repaints_painted());
  headless_print("drawn-tiles-set-up " + rg_screen_drawn_tiles_set_up());
  headless_print("pages " + (rg_screen_two_pages() != 0 ? 2 : 1));
  headless_exit(0, "");
}

/* A frame boundary, after the game has handed it back: the next frame begun and shown, and its buttons
 * asked for — or the run over, once it has played every frame it was asked for. */
/* The frame's sound, written down as rg_headless.js writes it: a sample of the left speaker, then the right's at the same
 * moment, and so on, handed to the harness a frame at a time. Worked out only for a run that records it. */
static function headless_write_frame_sound():Void {
  if (!headless_sound_out) return;
  if (headless_hex_bytes == null) headless_hex_bytes = [for (b in 0...256) StringTools.hex(b, 2)];
  var count = rg_sound_render_frame(headless_left, headless_right);
  var parts:Array<String> = [];
  for (i in 0...count) {
    var l = headless_left[i];
    var r = headless_right[i];
    parts.push(headless_hex_bytes[l & 0xFF]);
    parts.push(headless_hex_bytes[(l >> 8) & 0xFF]);
    parts.push(headless_hex_bytes[r & 0xFF]);
    parts.push(headless_hex_bytes[(r >> 8) & 0xFF]);
  }
  flash.external.ExternalInterface.call("rg_write_sound", parts.join(""));
}

/* The state read in or written out at this frame boundary, as the options asked: read in at the first boundary, written
 * where the frames started so far are the number asked for. */
static function headless_state_at_boundary():Void {
  if (headless_state_in != null) {
    var text = headless_state_in;
    headless_state_in = null;
    rg_state_read(text);
  }
  if (!headless_state_out || headless_frame != headless_state_out_after) return;
  flash.external.ExternalInterface.call("rg_write_state", haxe.io.Bytes.ofString(rg_state_write()).toHex());
}

static function headless_wait_vblank():Void {
  headless_state_at_boundary();
  if (rg_frame_ends_late() != 0) {
    headless_write_frame_sound();
    rg_frame_begins();
  } else {
    if (headless_sound_held_up == 0) headless_write_frame_sound();
    if (headless_frame >= headless_frames_to_play) {
      headless_finish();
      return;
    }
    var held_up = rg_frame_begins();
    headless_sound_held_up = held_up;
    headless_frame++;
    if (held_up != 0) return;
  }
  headless_print_moment("frame " + headless_frame, headless_every_picture);
  headless_print("buttons?");
  headless_waiting_for_buttons = true;
}

/* A line of buttons: one number for each connected player, the first player's first (IR::Buttons.masks),
 * separated by spaces. Players past RG_MOST_PLAYERS are not read. */
static function headless_players(line:String):Array<Int> {
  var masks:Array<Int> = [];
  if (line == null) return masks;
  for (word in StringTools.trim(line).split(" ")) {
    var mask = Std.parseInt(word);
    if (mask == null || masks.length >= RG_MOST_PLAYERS) break;
    masks.push(mask);
  }
  return masks;
}

/* --- what the harness calls --- */

/* What the C and JavaScript programs take that this one does not yet, each refused by name rather than played without. */
static var HEADLESS_REFUSED:Array<String> = ["--start-file"];
static var HEADLESS_REFUSED_WORDS:Array<String> = ["a file handed to the game as it starts"];

static function headless_start(given:String):Void {
  var options = given.split("\n");
  headless_frames_to_play = Std.parseInt(options.shift());
  var at = 0;
  while (at < options.length) {
    var option = options[at];
    if (option == "--every-picture") {
      headless_every_picture = true;
    } else if (option == "--held-from-power-on" && at + 1 < options.length) {
      rg_players_held_from_power_on(headless_players(options[at + 1]));
      at++;
    } else if (option == "--save-bytes" && at + 1 < options.length) {
      if (!rg_save_load_hex(options[at + 1])) {
        headless_exit(2, "the file the game was handed is not this game's save memory, which is " + rg_save_size() + " bytes");
        return;
      }
      at++;
    } else if (option == "--save-cut-after" && at + 1 < options.length) {
      rg_save_cut_power_after(Std.parseInt(options[at + 1]));
      at++;
    } else if (option == "--sound-out") {
      headless_sound_out = true;
    } else if (option == "--state-out") {
      headless_state_out = true;
    } else if (option == "--state-out-after" && at + 1 < options.length) {
      headless_state_out_after = Std.parseInt(options[at + 1]);
      at++;
    } else if (option == "--state-in") {
      // the harness read the file, and hands its bytes over as hex digits after --state-bytes
    } else if (option == "--state-bytes" && at + 1 < options.length) {
      headless_state_in = haxe.io.Bytes.ofHex(options[at + 1]).toString();
      at++;
    } else if (option == "--sound-voice" && at + 1 < options.length) {
      rg_sound_hear_only(Std.parseInt(options[at + 1]));
      at++;
    } else if (HEADLESS_REFUSED.indexOf(option) >= 0) {
      headless_exit(RG_GAME_WENT_WRONG, "the Flash build does not take " + option + " yet: " + HEADLESS_REFUSED_WORDS[HEADLESS_REFUSED.indexOf(option)]);
      return;
    } else if (option == "--clock-at" && at + 3 < options.length) {
      rg_clock_starts_at(Std.parseFloat(options[at + 1]), Std.parseInt(options[at + 2]), Std.parseInt(options[at + 3]));
      at += 3;
    }
    at++;
  }
  headless_started = true;
}

static function headless_buttons(line:String):Void {
  rg_players_read(headless_players(line));
  headless_waiting_for_buttons = false;
}

static function headless_picture():String { return headless_picture_string(); }

/* Plays the game from where it stopped to its next frame boundary, the pass the harness's frame is: each
 * time rg_game_pass gives back 1, a frame has ended (its routines are resumable, Computer::Resumable). A
 * game that stops — halted, gone wrong, or run out of program — ends the run. */
static function headless_on_frame(_:flash.events.Event):Void {
  if (!headless_started || headless_waiting_for_buttons || headless_over) return;
  try {
    while (!headless_waiting_for_buttons && !headless_over) {
      if (rg_game_pass() == 0) {
        headless_finish();
        return;
      }
      headless_wait_vblank();
    }
  } catch (stopped:RgStopped) {
    if (stopped.wentWrong) headless_exit(RG_GAME_WENT_WRONG, stopped.message);
    else headless_finish();
  } catch (error:Dynamic) {
    // Anything else the player raises (an index past a vector, a null routine) is the game going wrong too: a
    // pass is not carried on from the middle of a step.
    var said = Std.isOfType(error, flash.errors.Error) ? cast(error, flash.errors.Error).message : Std.string(error);
    headless_exit(RG_GAME_WENT_WRONG, said);
  }
}

/* A line of the sound log, as it happens. */
static function rg_sound_logged(line:String):Void { headless_print("sound " + line); }

/* The driver's part of what the game asks of its runtime. */
static function rg_dump_variable(name:String, value:Int):Void { headless_print("var " + name + " " + value); }

static function rg_dump_list(list:RgList):Void {
  var items:Array<String> = [];
  for (i in 0...list.length) items.push(Std.string(list.items[rg_list_slot(list, i)]));
  headless_print("list " + list.name + "\t" + items.join(" "));
}

static function main():Void {
  flash.external.ExternalInterface.addCallback("rg_start", headless_start);
  flash.external.ExternalInterface.addCallback("rg_buttons", headless_buttons);
  flash.external.ExternalInterface.addCallback("rg_picture", headless_picture);
  flash.external.ExternalInterface.addCallback("rg_save_hex", rg_save_hex);
  flash.Lib.current.addEventListener(flash.events.Event.ENTER_FRAME, headless_on_frame);
}
