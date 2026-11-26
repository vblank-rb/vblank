/*
 * Everything the game asks of the machine it runs on that is not the picture, the sound or the save
 * memory (the JavaScript runtime's rg_runtime.js): the buttons, the timers, the end of a frame, and
 * stopping.
 *
 * The game never names a stage or a file. It calls these, and the driver it was built with answers what
 * only a driver can: rg_headless.hx, which a test plays, or rg_page.hx, which draws on the stage. A driver
 * defines rg_dump_variable and rg_dump_list, plays the game by calling rg_game_pass for one frame after
 * another (see Printer), and says what halting and going wrong mean.
 *
 * What is not here yet: the cartridge's clock, the start file, and the state image. A game that needs
 * one is refused by name before it is built (Flash#runtime_gaps).
 */

/* The game did something the interpreter refuses: says so in +message+ and stops. A driver with no window
 * ends with RG_GAME_WENT_WRONG, so whoever started it can tell the game going wrong from the program
 * failing in its own right. */
static inline var RG_GAME_WENT_WRONG:Int = 3;
static function rg_fault(message:String):Void { throw new RgStopped(message, true); }

/* The game stopped on purpose (`halt`), which stops the motor too. Never comes back. */
static function rg_halt():Void {
  rumble_left = 0;
  motor_on = 0;
  throw new RgStopped("halt", false);
}

/* --- the motor (Reference#exec_rumble, #step_motor) --- */

static var rumble_left:Int = 0;
static var rumble_bits:Int = 0;
static var motor_on:Int = 0;

static function rg_rumble(frames:Int, pattern:Int):Void {
  if (RG_CONSOLE_RUMBLES == 0) return;
  rumble_left = frames < 0 ? 0 : (frames > 0xFFFF ? 0xFFFF : frames);
  rumble_bits = pattern & 0xFF;
}

static function rg_motor_frame():Void {
  if (rumble_left <= 0) {
    motor_on = 0;
    return;
  }
  rumble_bits = ((rumble_bits >> 1) | (rumble_bits << 7)) & 0xFF;
  motor_on = rumble_bits & 1;
  rumble_left--;
}

static function rg_motor_on():Int { return motor_on; }

/* --- tables --- */

/* A table of the game's numbers, written into the file as base64 (see Printer#print_const_array) and made
 * into a vector when the movie starts. +kind+ is the C type the table is kept as. The bytes are
 * little-endian. */
static function rg_table_from_base64(kind:String, text:String):Vector<Int> {
  var bytes = haxe.crypto.Base64.decode(StringTools.replace(text, "\n", ""));
  var size = kind == "int32_t" ? 4 : (kind == "int16_t" || kind == "uint16_t" ? 2 : 1);
  var count = Std.int(bytes.length / size);
  var table = new Vector<Int>(count);
  for (i in 0...count) {
    table[i] = switch (kind) {
      case "int8_t": var b = bytes.get(i); b >= 128 ? b - 256 : b;
      case "int16_t": bytes.getUInt16(i * 2) >= 32768 ? bytes.getUInt16(i * 2) - 65536 : bytes.getUInt16(i * 2);
      case "uint16_t": bytes.getUInt16(i * 2);
      case "int32_t": bytes.getInt32(i * 4);
      default: bytes.get(i);
    }
  }
  return table;
}

/* --- buttons --- */

/* Each player's buttons, a number each, the first player's first (IR::Buttons.masks), a bit a button in
 * IR::Buttons::NAMES's order. RG_ONE_PLAYERS_BUTTONS, written ahead of the runtime
 * (Computer::ConsoleNumbers), has every button's bit set. The lists are as long as the most players any
 * build reads; only the first +rg_connected+ can hold anything, and a player past them holds nothing. */
static var rg_buttons_held:Vector<Int> = new Vector<Int>(RG_MOST_PLAYERS);    /* buttons down now */
static var rg_buttons_seen:Vector<Int> = new Vector<Int>(RG_MOST_PLAYERS);    /* ...and at the last frame boundary, to tell a press from a hold */
static var rg_buttons_pressed:Vector<Int> = new Vector<Int>(RG_MOST_PLAYERS); /* buttons that went down at the last frame boundary */
static var rg_buttons_pulls:Vector<Int> = new Vector<Int>(RG_MOST_PLAYERS);   /* how far the triggers are part pulled, above the buttons' bits */
static var rg_connected:Int = 1; /* players connected: never fewer than the driver has said */

/* +masks+, one number for each player a driver reports is connected, as held now. A player stays connected
 * once a driver has reported it, and one it leaves out holds nothing. */
static function rg_hold_players(masks:Array<Int>):Void {
  var count = masks.length > RG_MOST_PLAYERS ? RG_MOST_PLAYERS : masks.length;
  if (count > rg_connected) rg_connected = count;
  for (player in 0...RG_MOST_PLAYERS) {
    rg_buttons_held[player] = player < count ? masks[player] & RG_ONE_PLAYERS_BUTTONS : 0;
    rg_buttons_pulls[player] = player < count ? masks[player] & ~RG_ONE_PLAYERS_BUTTONS : 0;
  }
}

/* A driver reports which buttons are down at every frame boundary. A button counts as pressed on the one
 * frame it goes down, however long it is then held. */
static function rg_players_read(masks:Array<Int>):Void {
  rg_hold_players(masks);
  for (player in 0...RG_MOST_PLAYERS) {
    rg_buttons_pressed[player] = rg_buttons_held[player] & ~rg_buttons_seen[player];
    rg_buttons_seen[player] = rg_buttons_held[player];
  }
}

/* Down before the first frame boundary and not yet seen there, so the first boundary still finds them going down. */
static function rg_players_held_from_power_on(masks:Array<Int>):Void { rg_hold_players(masks); }

/* A button's bit in +buttons+, or any of the first player's for -1. */
static function rg_button_down(buttons:Int, button:Int):Int {
  if (button < 0) return (buttons & RG_ONE_PLAYERS_BUTTONS) != 0 ? 1 : 0;
  return (buttons >> button) & 1;
}

static function rg_held(button:Int):Int { return rg_button_down(rg_buttons_held[0], button); }
static function rg_pressed(button:Int):Int { return rg_button_down(rg_buttons_pressed[0], button); }

/* Whether any of the buttons in +mask+ is down for +player+ (1 and up), or for any connected player for 0. */
static function rg_down_by(buttons:Vector<Int>, player:Int, mask:Int):Int {
  if (player == 0) {
    for (each in 0...rg_connected) if ((buttons[each] & mask) != 0) return 1;
    return 0;
  }
  if (player < 1 || player > RG_MOST_PLAYERS) return 0;
  return (buttons[player - 1] & mask) != 0 ? 1 : 0;
}

static function rg_held_by(player:Int, mask:Int):Int { return rg_down_by(rg_buttons_held, player, mask); }
static function rg_pressed_by(player:Int, mask:Int):Int { return rg_down_by(rg_buttons_pressed, player, mask); }

/* How far a trigger is pulled: the part pull handed (seven bits from +shift+, nought for none), or all or
 * nothing as the button is held. */
static function rg_pulled(button:Int, shift:Int, player:Int):Int {
  if (player < 1 || player > RG_MOST_PLAYERS) return 0;
  var part = (rg_buttons_pulls[player - 1] >>> shift) & ((1 << RG_PULL_BITS) - 1);
  if (part != 0) return part;
  return rg_button_down(rg_buttons_held[player - 1], button) != 0 ? 100 : 0;
}

/* How many players are connected now. */
static function rg_players_connected():Int { return rg_connected; }

/* Which player the person at this machine is, and the seed machines in one match share for the game's
 * random numbers: the first player and nought, since no match is played in Flash yet. */
static var rg_local_player_number:Int = 1;
static var rg_match_seed_number:Int = 0;
static function rg_local_player():Int { return rg_local_player_number; }
static function rg_match_seed():Int { return rg_match_seed_number; }

/* --- the end of a frame --- */

/* The frame the game drew has ended; the game then gives back 1 from rg_game_pass, and the driver takes the frame. */
static function rg_wait_vblank():Void { rg_screen_frame_ended(); }

/* A routine the runtime asked for an answer cannot wait for a frame: the answer is wanted now. */
static function rg_wait_vblank_while_answering():Void {
  rg_fault("the game waited for the screen while working out an answer the picture or a timer asked for");
}

/* --- timers (Reference @timers) --- */

static inline var RG_MAX_TIMERS:Int = 32;

/* One timer each, all noughts until started: nothing works out a timer's ticks before it is. */
static var rg_timers:Array<RgTimer> = [for (i in 0...RG_MAX_TIMERS) new RgTimer()];

static function rg_timer_whole_ticks(timer:RgTimer):Int { return Std.int(rg_floor(timer.parts / timer.framesASecond)); }

/* The timers in the order each was first started, which is the order the interpreter walks them. */
static var rg_timers_started:Array<Int> = [];
static var rg_timer_now_ticking:Int = -1;

static function rg_fault_unless_timer(timer:Int):Void {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault("timer number " + timer + " is not one of the " + RG_MAX_TIMERS + " there is room for");
}

static function rg_timer_start(timer:Int, ticks_a_second:Int, frames_a_second:Int):Void {
  rg_fault_unless_timer(timer);
  if (rg_timers[timer].started == 0) rg_timers_started.push(timer);
  var started = new RgTimer();
  started.started = 1;
  started.running = 1;
  started.ticksASecond = ticks_a_second;
  started.framesASecond = frames_a_second;
  rg_timers[timer] = started;
}

static function rg_timer_stop(timer:Int):Void {
  rg_fault_unless_timer(timer);
  rg_timers[timer].running = 0;
}

static function rg_timer_ticks(timer:Int):Int {
  rg_fault_unless_timer(timer);
  return rg_timers[timer].started != 0 ? rg_timer_whole_ticks(rg_timers[timer]) % 65536 : 0;
}

static function rg_timer_ticking(timer:Int):Int { return timer == rg_timer_now_ticking ? 1 : 0; }

/* A frame's worth of ticks more for +timer+ (Reference#accrue_timer), and how many whole ticks that
 * crossed, settled before the first handler runs. */
static function rg_timer_ticks_crossed(timer:RgTimer):Int {
  var before = rg_timer_whole_ticks(timer);
  timer.parts += timer.ticksASecond;
  return rg_timer_whole_ticks(timer) - before;
}

/* A handler that waits: the boundary's walk through the timers stops where a handler waits and carries
 * on later. */
static inline var RG_HANDLER_NONE_STOPPED:Int = 0;
static inline var RG_HANDLER_STOPPED:Int = 1;
static inline var RG_HANDLER_WAIT_OVER:Int = 2;
static var rg_walk_place:Int = 0;
static var rg_walk_ticks_left:Int = 0;
static var rg_handler_state:Int = RG_HANDLER_NONE_STOPPED;
static var rg_handler_waited:Int = 0;
static var rg_frame_end_pending:Int = 0;

static function rg_timer_handler_waited(waited:Int):Void { rg_handler_waited = waited; }
static function rg_timer_handler_paused():Int { return rg_handler_state != RG_HANDLER_NONE_STOPPED ? 1 : 0; }
static function rg_frame_ends_late():Int { return rg_frame_end_pending; }

/* The boundary's walk through every running timer, from where it stopped: 1 when a handler stopped to
 * wait (marked RG_HANDLER_STOPPED), 0 when it is over. */
static function rg_walk_timers():Int {
  rg_handler_state = RG_HANDLER_NONE_STOPPED;
  while (rg_walk_place < rg_timers_started.length) {
    var number = rg_timers_started[rg_walk_place];
    var skipped = false;
    if (rg_walk_ticks_left == 0) {
      if (rg_timers[number].running == 0) skipped = true;
      else rg_walk_ticks_left = rg_timer_ticks_crossed(rg_timers[number]);
    }
    if (!skipped) {
      while (rg_walk_ticks_left > 0) {
        rg_timer_now_ticking = number;
        rg_handler_waited = 0;
        rg_game_timer_ticks();
        rg_timer_now_ticking = -1;
        if (rg_handler_waited != 0) {
          rg_handler_state = RG_HANDLER_STOPPED;
          return 1;
        }
        rg_walk_ticks_left--;
      }
    }
    rg_walk_place++;
  }
  rg_walk_place = 0;
  return 0;
}

/* The same at a boundary inside a stopped handler's wait: each handler run to its end. */
static function rg_timers_frame_inside_wait():Void {
  for (number in rg_timers_started) {
    var timer = rg_timers[number];
    if (timer.running == 0) continue;
    var crossed = rg_timer_ticks_crossed(timer);
    rg_timer_now_ticking = number;
    for (tick in 0...crossed) rg_game_timer_ticks();
    rg_timer_now_ticking = -1;
  }
}

/* The game's next pass: rg_game_main, or a stopped handler carried on once its wait's boundary is over. */
static function rg_game_pass():Int {
  if (rg_handler_state == RG_HANDLER_NONE_STOPPED) return rg_game_main();
  if (rg_handler_state == RG_HANDLER_STOPPED) return 1;
  if (rg_walk_timers() == 0) rg_frame_end_pending = 1;
  return 1;
}

/* The end of the middle of Reference#advance_frame: the frame is counted. */
static function rg_frame_ends():Void {
  rg_motor_frame();
}

/* The middle of Reference#advance_frame, in its order: the picture switched on, the timers tick, then the
 * frame ends (#rg_frame_ends) — or only as far as a handler that stopped, or only the end of the frame its
 * walk began. 1 where the handler stopped, and nothing is shown yet. */
static function rg_frame_begins():Int {
  if (rg_frame_end_pending != 0) {
    rg_frame_end_pending = 0;
    rg_frame_ends();
    return 0;
  }
  rg_screen_frame_started();
  if (rg_handler_state != RG_HANDLER_NONE_STOPPED) {
    rg_timers_frame_inside_wait();
    rg_handler_state = RG_HANDLER_WAIT_OVER;
  } else if (rg_walk_timers() != 0) {
    return 1;
  }
  rg_frame_ends();
  return 0;
}
