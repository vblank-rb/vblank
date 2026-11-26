/*
 * The game's save memory: the bytes a cartridge's chip keeps while the console is off, laid out byte for byte
 * the way the chip is, so what a driver keeps of them is a .sav file. A port of the JavaScript runtime's
 * rg_save.js, which is a port of the native runtime's rg_save.c (IR::SaveImage, a method at a time).
 *
 * A driver keeps them: the headless one in the file the harness writes (rg_start's --save-bytes and the
 * harness's rg_save_hex), the page's in a SharedObject (rg_page.hx).
 */

static inline var SAVE_MOST_BYTES:Int = 128 * 1024;
static inline var SAVE_QUIET_FRAMES:Int = 2;
static inline var SAVE_MOST_FRAMES_UNWRITTEN:Int = 60;

static var save_bytes:Vector<Int> = new Vector<Int>(SAVE_MOST_BYTES);
static var save_awake:Int = 0;
static var power_left:Int = -1;
static var wiping:Int = -1;
static var save_unwritten:Int = 0;
static var save_frames_quiet:Int = 0;
static var save_frames_unwritten:Int = 0;

static function save_size():Int { return rg_game_save_memory[0]; }
static function wiped_together():Int { return rg_game_save_memory[1]; }
static function fresh_byte():Int { return rg_game_save_memory[2] & 0xFF; }
static function busy_byte():Int { return rg_game_save_memory[3] & 0xFF; }

static function save_wake():Void {
  if (save_awake != 0) return;
  save_awake = 1;
  if (save_size() > SAVE_MOST_BYTES) rg_fault("this game has " + save_size() + " bytes of save memory, and the most is " + SAVE_MOST_BYTES);
  for (i in 0...save_size()) save_bytes[i] = fresh_byte();
}

static function save_changed():Void {
  save_unwritten = 1;
  save_frames_quiet = 0;
}

static function hex(number:Int):String { return StringTools.hex(number); }
static function hex_byte(number:Int):String { return StringTools.hex(number, 2); }

static function refuse_outside_memory(did:String, at:Int, count:Int):Void {
  if (at >= 0 && at + count <= save_size()) return;
  rg_fault("The program " + did + " save memory at 0x" + hex(at) + ", and save memory is " + Std.int(save_size() / 1024) + "K, " +
    "which ends at 0x" + hex(save_size()) + ". A program must keep to the save memory it has.");
}

static function refuse_while_wiping(did:String, at:Int):Void {
  if (wiping < 0) return;
  rg_fault("The program " + did + " flash save memory at 0x" + hex(at) + " while the chip was still wiping the block at " +
    "0x" + hex(wiping) + ". After the program starts a wipe, it must read the block until the block reads 0xFF.");
}

static function refuse_write_needing_wipe(at:Int, byte:Int):Void {
  var held_byte = save_bytes[at];
  if ((byte & ~held_byte & 0xFF) == 0) return;
  rg_fault("The program wrote 0x" + hex_byte(byte) + " to flash save memory at 0x" + hex(at) + ", which holds 0x" + hex_byte(held_byte) + ". " +
    "Flash cannot take that byte there. Before the program writes over a block of flash, it must wipe the block.");
}

static function refuse_without_power():Void {
  if (power_left == 0) rg_halt();
}

static function spend_power():Void {
  refuse_without_power();
  if (power_left > 0) power_left--;
}

/* One byte as SaveImage#read_bytes reads it; the first of +busy+ is set where a block being wiped was read. */
static function read_save_byte(at:Int, busy:Array<Bool>):Int {
  if (wiping < 0 || at < wiping || at >= wiping + wiped_together()) return save_bytes[at];
  busy[0] = true;
  return busy_byte();
}

static function rg_save_read(at:Int, width:Int):Int {
  save_wake();
  refuse_outside_memory("read", at, width);
  var value:Float = 0;
  var busy = [false];
  for (i in 0...width) value += read_save_byte(at + i, busy) * Math.pow(2, 8 * i);
  if (busy[0]) wiping = -1;
  return Std.int(value);
}

static function rg_save_sum(at:Int, length:Int):Int {
  save_wake();
  refuse_outside_memory("read", at, length);
  var low = 0;
  var high = 0;
  var busy = [false];
  for (i in 0...length) {
    low = (low + read_save_byte(at + i, busy)) & 0xFFFF;
    high = (high + low) & 0xFFFF;
  }
  if (busy[0]) wiping = -1;
  return (high << 16) | low;
}

static function rg_save_write(at:Int, value:Int, width:Int):Void {
  save_wake();
  refuse_outside_memory("wrote to", at, width);
  for (i in 0...width) {
    spend_power();
    var byte = (value >>> (8 * i)) & 0xFF;
    if (wiped_together() > 0) {
      refuse_while_wiping("wrote to", at + i);
      refuse_write_needing_wipe(at + i, byte);
    }
    save_bytes[at + i] = byte;
    save_changed();
  }
}

static function rg_save_erase(at:Int, wait:Int):Void {
  save_wake();
  var save_block = wiped_together();
  if (save_block == 0) return;
  refuse_without_power();
  refuse_outside_memory("wiped", at, 1);
  refuse_while_wiping("wiped", at);
  var start = Std.int(at / save_block) * save_block;
  if (power_left == 1) {
    for (i in start...start + Std.int(save_block / 2)) save_bytes[i] = fresh_byte();
    save_changed();
    power_left = 0;
    rg_halt();
  }
  if (power_left > 0) power_left -= 2;
  for (i in start...start + save_block) save_bytes[i] = fresh_byte();
  save_changed();
  if (wait == 0) wiping = start;
}

static function rg_save_size():Int { return save_size(); }

/* Every byte of save memory, as a .sav file holds them, as two hex digits each. */
static function rg_save_hex():String {
  if (save_size() == 0) return "";
  save_wake();
  var digits = new StringBuf();
  for (i in 0...save_size()) digits.add(StringTools.hex(save_bytes[i], 2));
  return digits.toString();
}

/* The bytes a .sav file holds (as hex digits), put in as the memory the game starts with; whether they were
 * the size of this game's. */
static function rg_save_load_hex(digits:String):Bool {
  save_wake();
  if (digits.length != save_size() * 2) return false;
  for (i in 0...save_size()) save_bytes[i] = Std.parseInt("0x" + digits.substr(i * 2, 2));
  return true;
}

static function rg_save_unwritten():Int { return save_unwritten; }

static function rg_save_file_is_due():Int {
  if (save_unwritten == 0) return 0;
  save_frames_quiet++;
  save_frames_unwritten++;
  if (save_frames_quiet != SAVE_QUIET_FRAMES && save_frames_unwritten < SAVE_MOST_FRAMES_UNWRITTEN) return 0;
  save_frames_unwritten = 0;
  return 1;
}

static function rg_save_file_written():Void {
  save_unwritten = 0;
  save_frames_unwritten = 0;
}

static function rg_save_cut_power_after(steps:Int):Void { power_left = steps; }
