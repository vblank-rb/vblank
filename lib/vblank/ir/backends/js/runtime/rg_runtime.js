/*
 * Everything the game asks of the machine it runs on that is not the picture, the sound or the
 * save memory (the native runtime's rg_runtime.c): the buttons, the timers, the end of a frame,
 * and stopping.
 *
 * The game never names a page, a canvas or a file. It calls these, and the DRIVER that started it
 * answers what only a driver can: rg_headless.js, which node runs and prints from, or rg_page.js,
 * which draws to a canvas. A driver sets rg_active_driver to an object with these:
 *
 *   halted()                   the game stopped on purpose (`halt`)
 *   dump_variable(name, value) one variable, for the driver to print if it prints
 *   dump_list(list)            one list, the same way
 *   sound_logged(line)         one line of the sound log, as it happens
 *
 * and plays the game by calling rg_game_main for one frame after another (see Printer).
 */

let rg_active_driver = null;

/* The game stopped, on purpose or because it went wrong. Thrown rather than returned, so it
 * comes out of however deep in the game's routines it happened, and the driver catches it. */
class RgStopped extends Error {
  constructor(message, went_wrong) {
    super(message);
    this.went_wrong = went_wrong;
  }
}

/* The game did something the interpreter refuses: says so in +message+ and stops. A driver with
 * no window ends with RG_GAME_WENT_WRONG, so whoever started it can tell the game going wrong from
 * the program failing in its own right. */
const RG_GAME_WENT_WRONG = 3;
function rg_fault(message) { throw new RgStopped(message, true); }

/* The game stopped on purpose (`halt`), which stops the motor too. Never comes back. */
function rg_halt() {
  rumble_left = 0;
  motor_on = 0;
  throw new RgStopped("halt", false);
}

/* --- the motor (Reference#exec_rumble, #step_motor) --- */

/* The cartridge's motor, kept as the native runtime keeps it (rg_runtime.c says how a pattern is
 * read), on a console whose cartridge carries one. A web page shakes no gamepad yet. */
let rumble_left = 0, rumble_bits = 0, motor_on = 0;

function rg_rumble(frames, pattern) {
  if (!RG_CONSOLE_RUMBLES) return;
  rumble_left = Math.min(Math.max(frames, 0), 0xFFFF);
  rumble_bits = pattern & 0xFF;
}

function rg_motor_frame() {
  if (rumble_left <= 0) {
    motor_on = 0;
    return;
  }
  rumble_bits = ((rumble_bits >> 1) | (rumble_bits << 7)) & 0xFF;
  motor_on = rumble_bits & 1;
  rumble_left--;
}

function rg_motor_on() { return motor_on; }

/* --- the state image (rg_state.js) --- */

/* A typed array of numbers as a field, written as it stands or filled from the image. */
function rg_runtime_visit_array(name, array) {
  const values = Array.from(array);
  rg_state_numbers(name, values);
  array.set(values);
}

/* Every timer as five numbers: started, running, its rate, its frames a second, and how far it has
 * ticked. Then the order they were first started in: how many, and the timers' numbers (-1 for none). */
function rg_runtime_visit_timers() {
  const values = [];
  for (const timer of rg_timers) {
    values.push(timer.started, timer.running, timer.ticks_a_second, timer.frames_a_second, timer.parts);
  }
  rg_state_numbers("runtime.timers", values);
  for (let i = 0; i < RG_MAX_TIMERS; i++) {
    const [started, running, ticks_a_second, frames_a_second, parts] = values.slice(i * 5, i * 5 + 5);
    rg_timers[i] = { started, running, ticks_a_second, frames_a_second, parts };
  }
  const order = [rg_timers_started.length];
  for (let i = 0; i < RG_MAX_TIMERS; i++) order.push(i < rg_timers_started.length ? rg_timers_started[i] : -1);
  rg_state_numbers("runtime.timers.order", order);
  rg_timers_started.length = order[0];
  for (let i = 0; i < order[0]; i++) rg_timers_started[i] = order[i + 1];
}

/* The runtime's own fields, in Computer::StateFields's order. */
function rg_runtime_visit_state() {
  rg_runtime_visit_array("runtime.buttons.held", rg_buttons_held);
  rg_runtime_visit_array("runtime.buttons.seen", rg_buttons_seen);
  rg_runtime_visit_array("runtime.buttons.pressed", rg_buttons_pressed);
  rg_connected = rg_state_number("runtime.players.connected", rg_connected);
  rg_runtime_visit_timers();
  const clock = [rg_clock_present, rg_clock_set, rg_clock_counts_frames, rg_clock_seconds, rg_clock_ticks,
                 rg_clock_days_kept, rg_clock_seconds_kept];
  rg_state_numbers("runtime.clock", clock);
  [rg_clock_present, rg_clock_set, rg_clock_counts_frames, rg_clock_seconds, rg_clock_ticks,
   rg_clock_days_kept, rg_clock_seconds_kept] = clock;
  const motor = [rumble_left, rumble_bits, motor_on];
  rg_state_numbers("runtime.motor", motor);
  [rumble_left, rumble_bits, motor_on] = motor;
}

/* --- tables --- */

/* A table of the game's numbers, written into the file as base64 (see Printer#print_const_array)
 * and made into a typed array of +Type+ when the script starts. JavaScript's own. A big game
 * carries millions of numbers — its maps, its pictures, its sound — and written as an array
 * literal each one is a piece of code for the browser to read and build, which runs a browser out
 * of memory before the game starts. A string is one piece however long it is. The bytes are
 * little-endian, read so on any machine; atob passes over the line breaks that keep the file
 * scrollable. */
function rg_table_from_base64(Type, text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return rg_table_from_bytes(Type, bytes, 0, bytes.length / Type.BYTES_PER_ELEMENT);
}

/* +count+ numbers of +Type+ from +bytes+ (a Uint8Array), starting +at+ that many bytes in: a table
 * written as base64, or one of the tables in a game's data file (see JS::Printer#data_file). */
function rg_table_from_bytes(Type, bytes, at, count) {
  const view = new DataView(bytes.buffer, bytes.byteOffset + at, count * Type.BYTES_PER_ELEMENT);
  const read = { Int8Array: "getInt8", Uint8Array: "getUint8", Int16Array: "getInt16", Uint16Array: "getUint16",
                 Int32Array: "getInt32" }[Type.name];
  const table = new Type(count);
  for (let i = 0; i < count; i++) table[i] = view[read](i * Type.BYTES_PER_ELEMENT, true);
  return table;
}

/* --- buttons --- */

const RG_ONE_PLAYERS_BUTTONS = 0x1FFF; /* thirteen, as IR::Buttons::NAMES has: the Genesis's C is the last */
const RG_MOST_PLAYERS = 16; /* IR::Buttons::MOST_PLAYERS */

/* EACH PLAYER'S BUTTONS, a number each, the first player's first (IR::Buttons.masks), a bit a
 * button in the order the console's key register holds them: a, b, select, start, right, left,
 * up, down, r, l. The lists are as long as the most players any build reads; only the first
 * +rg_connected+ can hold anything, and a player past them holds nothing. */
const rg_buttons_held = new Int32Array(RG_MOST_PLAYERS);    /* buttons down now */
const rg_buttons_seen = new Int32Array(RG_MOST_PLAYERS);    /* ...and at the last frame boundary, to tell a press from a hold */
const rg_buttons_pressed = new Int32Array(RG_MOST_PLAYERS); /* buttons that went down at the last frame boundary */
let rg_connected = 1; /* players connected: never fewer than the driver has said */

/* +masks+, one number for each player a driver reports is connected, as held now. A player stays
 * connected once a driver has reported it, and one it leaves out holds nothing. */
function rg_hold_players(masks) {
  const count = masks.length > RG_MOST_PLAYERS ? RG_MOST_PLAYERS : masks.length;
  if (count > rg_connected) rg_connected = count;
  for (let player = 0; player < RG_MOST_PLAYERS; player++)
    rg_buttons_held[player] = player < count ? (masks[player] | 0) & RG_ONE_PLAYERS_BUTTONS : 0;
}

/* A driver reports which buttons are down at every frame boundary. A button counts as pressed on the
 * one frame it goes down, however long it is then held. */
function rg_players_read(masks) {
  rg_hold_players(masks);
  for (let player = 0; player < RG_MOST_PLAYERS; player++) {
    rg_buttons_pressed[player] = rg_buttons_held[player] & ~rg_buttons_seen[player];
    rg_buttons_seen[player] = rg_buttons_held[player];
  }
}

/* Down before the first frame boundary and not yet seen there, so the first boundary still finds
 * them going down. */
function rg_players_held_from_power_on(masks) { rg_hold_players(masks); }

/* A button's bit in +buttons+, or any of the first player's for -1. */
function rg_button_down(buttons, button) {
  if (button < 0) return (buttons & RG_ONE_PLAYERS_BUTTONS) !== 0 ? 1 : 0;
  return (buttons >> button) & 1;
}

function rg_held(button) { return rg_button_down(rg_buttons_held[0], button); }
function rg_pressed(button) { return rg_button_down(rg_buttons_pressed[0], button); }

/* Whether any of the buttons in +mask+ is down for +player+ (1 and up), or for any connected
 * player for 0, for a test that names a player. */
function rg_down_by(buttons, player, mask) {
  if (player === 0) {
    for (let each = 0; each < rg_connected; each++)
      if ((buttons[each] & mask) !== 0) return 1;
    return 0;
  }
  if (player < 1 || player > RG_MOST_PLAYERS) return 0;
  return (buttons[player - 1] & mask) !== 0 ? 1 : 0;
}

function rg_held_by(player, mask) { return rg_down_by(rg_buttons_held, player, mask); }
function rg_pressed_by(player, mask) { return rg_down_by(rg_buttons_pressed, player, mask); }

/* How many players are connected now. */
function rg_players_connected() { return rg_connected; }

/* Which player the person at this machine is, and the seed machines in one match share for the game's
 * random numbers: the first player and nought until a match sets them (rg_lockstep.js, a driver). */
let rg_local_player_number = 1;
let rg_match_seed_number = 0;
function rg_local_player() { return rg_local_player_number; }
function rg_match_seed() { return rg_match_seed_number; }

/* --- the end of a frame --- */

/* The frame the game drew has ended; the game then gives back 1 from rg_game_main, and the driver
 * takes the frame. */
function rg_wait_vblank() { rg_screen_frame_ended(); }

/* A routine the runtime asked for an answer cannot wait for a frame: the answer is wanted now. */
function rg_wait_vblank_while_answering() {
  rg_fault("the game waited for the screen while working out an answer the picture or a timer asked for");
}

/* Calls a routine picked out of an array of them. */
function rg_call_routine(routine) { routine(); }

/* --- timers (Reference @timers) --- */

const RG_MAX_TIMERS = 32;

/* One timer: whether it has ever been started, whether it is running, its rate, and how far it has
 * ticked since it was last started, in frames_a_second-ths of a tick — whole numbers, as the
 * interpreter keeps them (Reference#accrue_timer), so the two cross a whole tick on the same frame.
 * A JavaScript number holds a whole number exactly far past any count a game reaches, and the
 * division below is then exact too. */
const rg_timers = [];
/* All noughts until started, as C's start: nothing works out a timer's ticks before it is. */
for (let i = 0; i < RG_MAX_TIMERS; i++) rg_timers.push({ started: 0, running: 0, ticks_a_second: 0, frames_a_second: 0, parts: 0 });
function rg_timer_whole_ticks(timer) { return Math.floor(timer.parts / timer.frames_a_second); }
/* The timers in the order each was first started, which is the order the interpreter walks them. */
const rg_timers_started = [];
let rg_timer_now_ticking = -1;

function rg_fault_unless_timer(timer) {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault(`timer number ${timer} is not one of the ${RG_MAX_TIMERS} there is room for`);
}

function rg_timer_start(timer, ticks_a_second, frames_a_second) {
  rg_fault_unless_timer(timer);
  if (!rg_timers[timer].started) rg_timers_started.push(timer);
  rg_timers[timer] = { started: 1, running: 1, ticks_a_second, frames_a_second, parts: 0 };
}

function rg_timer_stop(timer) {
  rg_fault_unless_timer(timer);
  rg_timers[timer].running = 0;
}

function rg_timer_ticks(timer) {
  rg_fault_unless_timer(timer);
  return rg_timers[timer].started ? rg_timer_whole_ticks(rg_timers[timer]) % 65536 : 0;
}

function rg_timer_ticking(timer) { return timer === rg_timer_now_ticking ? 1 : 0; }

/* Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
 * handler once for each whole tick crossed, how many settled before the first runs. */
function rg_timers_frame() {
  for (const number of rg_timers_started) {
    const timer = rg_timers[number];
    if (!timer.running) continue;
    const before = rg_timer_whole_ticks(timer);
    timer.parts += timer.ticks_a_second;
    const crossed = rg_timer_whole_ticks(timer) - before;
    rg_timer_now_ticking = number;
    for (let tick = 0; tick < crossed; tick++) rg_game_timer_ticks();
    rg_timer_now_ticking = -1;
  }
}

/* The middle of Reference#advance_frame, in its order: the picture switched on, the timers tick,
 * then the mix, the tune, and every sounding note's shape, and then the frame is counted, which
 * moves a clock started at a test's moment. */
function rg_frame_begins() {
  rg_screen_frame_started();
  rg_timers_frame();
  rg_sound_frame();
  rg_motor_frame();
  rg_clock_frame();
}

/* --- the cartridge's clock (Reference#value_of_clock) --- */

/* The readings in IR::Clock::READINGS's order, which is the number the game asks by. Nothing ties
 * the two together but the JavaScript run of test_clock.rb, which reads every one of them. */
const RG_CLOCK_HOUR = 0, RG_CLOCK_MINUTE = 1, RG_CLOCK_SECOND = 2, RG_CLOCK_YEAR = 3, RG_CLOCK_MONTH = 4, RG_CLOCK_DAY = 5,
  RG_CLOCK_WEEKDAY = 6, RG_CLOCK_PRESENT = 7, RG_CLOCK_SET = 8;

const RG_SECONDS_A_DAY = 86400;

/* Whether there is a clock and it was set; whether it moves on a frame at each boundary rather
 * than being told the time; and the time now, as seconds from the start of 1970 and the console's
 * ticks into the next second. Every one a whole number well inside what a JavaScript number holds
 * exactly. */
let rg_clock_present = 0;
let rg_clock_set = 0;
let rg_clock_counts_frames = 0;
let rg_clock_seconds = 0;
let rg_clock_ticks = 0;

/* 1 January 2000, in days from the start of 1970: the day a clock that keeps no date reads as
 * starting on. */
const RG_UNDATED_FIRST_DAY = 10957;

/* The windowless driver starts the clock at a test's moment, and it moves on from there. A chip
 * that keeps no date (RG_CLOCK_KEEPS_DATE 0, the Color's; IR::Clock.undated) counts only the days
 * and the time of day since it started, taken as that many days on from 1 January 2000. */
function rg_clock_starts_at(seconds, ticks, set) {
  rg_clock_present = 1;
  rg_clock_set = set ? 1 : 0;
  rg_clock_counts_frames = 1;
  rg_clock_seconds = RG_CLOCK_KEEPS_DATE
    ? seconds
    : RG_UNDATED_FIRST_DAY * RG_SECONDS_A_DAY + (seconds - Math.floor(seconds / RG_SECONDS_A_DAY) * RG_SECONDS_A_DAY);
  rg_clock_ticks = ticks;
}

/* The days from the start of 1970 to a date, and back: the native runtime's calendar of plain
 * arithmetic, every fourth year a leap year, but not every hundredth, but every four hundredth.
 * Every division rounds down. Where C's own division cuts towards nothing, the numbers are never
 * below nothing and the two agree; where they can be (the era, the days, the weekday), rounding
 * down is what the C does too, so a moment before 1970 lands on the day it is in. */
function rg_days_from_date(year, month, day) {
  year -= month <= 2 ? 1 : 0;
  const era = Math.floor(year / 400);
  const year_of_era = year - era * 400;
  const day_of_year = Math.floor((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
  const day_of_era = year_of_era * 365 + Math.floor(year_of_era / 4) - Math.floor(year_of_era / 100) + day_of_year;
  return era * 146097 + day_of_era - 719468;
}

function rg_date_from_days(days) {
  days += 719468;
  const era = Math.floor(days / 146097);
  const day_of_era = days - era * 146097;
  const year_of_era = Math.floor((day_of_era - Math.floor(day_of_era / 1460) + Math.floor(day_of_era / 36524) -
                                  Math.floor(day_of_era / 146096)) / 365);
  const day_of_year = day_of_era - (365 * year_of_era + Math.floor(year_of_era / 4) - Math.floor(year_of_era / 100));
  const from_march = Math.floor((5 * day_of_year + 2) / 153);
  const month = from_march < 10 ? from_march + 3 : from_march - 9;
  return { year: year_of_era + era * 400 + (month <= 2 ? 1 : 0), month, day: day_of_year - Math.floor((153 * from_march + 2) / 5) + 1 };
}

/* The page gives what the browser's own clock reads instead, its local time, as each frame of the
 * game starts. */
function rg_clock_reads(year, month, day, hour, minute, second) {
  rg_clock_present = 1;
  rg_clock_set = 1;
  rg_clock_counts_frames = 0;
  rg_clock_seconds = rg_days_from_date(year, month, day) * RG_SECONDS_A_DAY + hour * 3600 + minute * 60 + second;
  rg_clock_ticks = 0;
}

/* A frame of the console's later: as many of its clock's ticks as it takes to draw one, close to
 * a sixtieth of a second (the console's RG_CONSOLE_TICKS_A_FRAME and RG_CONSOLE_TICKS_A_SECOND,
 * written ahead of the runtime). */
function rg_clock_frame() {
  if (!rg_clock_counts_frames) return;
  rg_clock_ticks += RG_CONSOLE_TICKS_A_FRAME;
  rg_clock_seconds += Math.floor(rg_clock_ticks / RG_CONSOLE_TICKS_A_SECOND);
  rg_clock_ticks %= RG_CONSOLE_TICKS_A_SECOND;
}

/* A time the game set is added on: how far it is from the clock's own, in whole days and the
 * seconds left over (IR::Clock::OFFSET_DAYS), 0 and 0 in a game that never sets one. */
function rg_clock_reading(reading, offset_days, offset_seconds) {
  if (!rg_clock_present) return 0;
  if (reading === RG_CLOCK_PRESENT) return 1;
  if (!rg_clock_set) return 0;
  /* A chip that keeps no date reads as never set until the game sets a time on it. */
  if (!RG_CLOCK_KEEPS_DATE && offset_days === 0 && offset_seconds === 0) return 0;
  if (reading === RG_CLOCK_SET) return 1;

  const now = rg_clock_seconds + offset_days * RG_SECONDS_A_DAY + offset_seconds;
  const days = Math.floor(now / RG_SECONDS_A_DAY);
  const into_day = now - days * RG_SECONDS_A_DAY;
  const date = rg_date_from_days(days);
  switch (reading) {
  case RG_CLOCK_HOUR: return Math.floor(into_day / 3600);
  case RG_CLOCK_MINUTE: return Math.floor(into_day / 60) % 60;
  case RG_CLOCK_SECOND: return into_day % 60;
  case RG_CLOCK_YEAR: return date.year;
  case RG_CLOCK_MONTH: return date.month;
  case RG_CLOCK_DAY: return date.day;
  case RG_CLOCK_WEEKDAY: return days + 4 - Math.floor((days + 4) / 7) * 7; /* 1 January 1970 was a Thursday */
  default: return rg_fault(`the clock has no reading numbered ${reading}`);
  }
}

/* SETTING THE CLOCK (rg_runtime.c's rg_clock_set_to): how far the time set is from the clock's
 * own, kept here until the game takes the two parts into its saved numbers. */
let rg_clock_days_kept = 0;
let rg_clock_seconds_kept = 0;

function rg_clock_set_to(year, month, day, hour, minute, second) {
  if (!rg_clock_present) return;
  const today = Math.floor(rg_clock_seconds / RG_SECONDS_A_DAY);
  let days = rg_days_from_date(year, month, day) - today;
  let seconds = hour * 3600 + minute * 60 + second - (rg_clock_seconds - today * RG_SECONDS_A_DAY);
  if (seconds < 0) {
    seconds += RG_SECONDS_A_DAY;
    days -= 1;
  }
  rg_clock_days_kept = days;
  rg_clock_seconds_kept = seconds;
  rg_clock_set = 1;
}

function rg_clock_kept_days(current) { return rg_clock_present ? rg_clock_days_kept : current; }
function rg_clock_kept_seconds(current) { return rg_clock_present ? rg_clock_seconds_kept : current; }

/* --- what the game hands the driver --- */

function rg_dump_variable(name, value) { rg_active_driver.dump_variable(name, value); }
function rg_dump_list(list) { rg_active_driver.dump_list(list); }

/* The game's name, as VBlank.game was given it, from the bytes the lowering writes it as. */
function rg_title() {
  let text = "";
  for (let i = 0; i < rg_game_title.length && rg_game_title[i] !== 0; i++) text += String.fromCharCode(rg_game_title[i]);
  return text;
}

/* --- the file the game is handed as it starts (rg_runtime.h says the rest) --- */

/* Its bytes, a Uint8Array, or null when none was handed over. */
let rg_start_file = null;

function rg_start_file_hand(bytes) { rg_start_file = Uint8Array.from(bytes); }

function rg_start_file_open(rules, missing, wrong_size, wrong_check) {
  const refusal = rg_start_file_refusal(rg_start_file, rules, { missing, wrong_size, wrong_check });
  if (refusal !== null) rg_fault(refusal);
}

/* The number +width+ bytes from +at+ in the file hold, low byte first, or high byte first where
 * +high_byte_first+ is 1, as a whole number from 0. */
function rg_start_file_number(at, width, high_byte_first) {
  let number = 0;
  for (let i = 0; i < width; i++) number = number * 256 + rg_start_file[at + (high_byte_first ? i : width - 1 - i)];
  return number;
}

/* Each entry goes into the table's own kind of array, which keeps the bits that kind keeps, so an
 * entry below zero comes out below zero. */
function rg_start_file_fill_table(table, kept, count, at, high_byte_first) {
  const width = kept === RG_TABLE_INT8 || kept === RG_TABLE_UINT8 ? 1 : kept === RG_TABLE_INT32 ? 4 : 2;
  for (let i = 0; i < count; i++) table[i] = rg_start_file_number(at + i * width, width, high_byte_first);
}

/* +count+ bytes of +samples+ from index +at+, each the file's byte from +file_at+ on, as a signed number. */
function rg_start_file_fill_bytes(samples, at, count, file_at) {
  for (let i = 0; i < count; i++) samples[at + i] = (rg_start_file[file_at + i] << 24) >> 24;
}

const RG_FILL_TILE = 0, RG_TURN_MIRRORED = 1, RG_TURN_UPSIDE_DOWN = 2;

/* The place of the pixel at +row+ and +column+ of a picture read from the file: +across+ tiles wide,
 * from +places_at+ on, each tile kept in the layout set by the numbers of +rules+ from +tile+ on (rg_runtime.c's
 * start_file_place). */
function rg_start_file_place(places_at, rules, tile, across, row, column) {
  const tile_bytes = rules[tile + RG_TILE_BYTES_AT], planes = rules[tile + RG_TILE_PLANES_AT], row_bits = rules[tile + RG_TILE_ROW_BITS_AT];
  const start = places_at + ((row >> 3) * across + (column >> 3)) * tile_bytes;
  let place = 0;
  for (let plane = 0; plane < planes; plane++) {
    const bit = rules[tile + RG_TILE_PLANE_BITS_AT + plane] + (row & 7) * row_bits + rules[tile + RG_TILE_COLUMN_BITS_AT + (column & 7)];
    place |= ((rg_start_file[start + (bit >> 3)] >> (bit & 7)) & 1) << plane;
  }
  return place;
}

/* rg_runtime.c's start_file_channel. */
function rg_start_file_channel(kept, at, bits) {
  const level = (kept >> at) & ((1 << bits) - 1);
  return bits >= 5 ? level : (level << (5 - bits)) | (level >> (2 * bits - 5));
}

/* Colour +place+ of the colours from +colors_at+ on, kept in the layout set by the numbers of +rules+ from +format+
 * (rg_runtime.c's start_file_color). */
function rg_start_file_color(colors_at, rules, format, place) {
  const kept = rg_start_file_number(colors_at + place * 2, 2, rules[format + RG_COLOR_HIGH_BYTE_FIRST_AT]);
  const bits = rules[format + RG_COLOR_CHANNEL_BITS_AT];
  return rg_start_file_channel(kept, rules[format + RG_COLOR_RED_AT], bits) |
    (rg_start_file_channel(kept, rules[format + RG_COLOR_GREEN_AT], bits) << 5) |
    (rg_start_file_channel(kept, rules[format + RG_COLOR_BLUE_AT], bits) << 10);
}

/* Colours that are no part of a picture, into the game's own array of them (rg_runtime.h,
 * rg_start_file_fill_colors). */
function rg_start_file_fill_colors(colors, first, count, at, format) {
  for (let place = 0; place < count; place++) colors[first + place] = rg_start_file_color(at, format, 0, place);
}

/* --- a recording's settings in the file (rg_runtime.h says what each of these is handed) --- */

const RG_FILE_NUMBER_NUMBERS = 4;

/* The number of a recording's setting, from the four numbers of +rules+ at +where+ (rg_runtime.c's
 * start_file_setting). */
function rg_start_file_setting(rules, where) {
  const width = rules[where + 1];
  const number = rg_start_file_number(rules[where], width, rules[where + 2]);
  const top = 2 ** (width * 8 - 1);
  return rules[where + 3] && number >= top ? number - top * 2 : number;
}

/* rg_runtime.c's number_of_halves. */
function rg_number_of_halves(high, low) {
  const view = new DataView(new ArrayBuffer(8));
  view.setInt32(0, high);
  view.setInt32(4, low);
  return view.getFloat64(0);
}

function rg_start_file_fill_steps(into, rules) {
  const rate = Math.max(rg_start_file_setting(rules, 0), 1);
  const rest = RG_FILE_NUMBER_NUMBERS;
  const mix_rate = rg_number_of_halves(rules[rest], rules[rest + 1]);
  const count = rules[rest + 2];
  for (let i = 0; i < count; i++) {
    const entry = rest + 3 + i * 3;
    const step = ((rate / mix_rate) * rg_number_of_halves(rules[entry + 1], rules[entry + 2])) * 65536;
    into[rules[entry]] = step >= 2147483647 ? 2147483647 : step < 1 ? 1 : Math.floor(step + 0.5);
  }
}

function rg_start_file_fill_holds(into, rules) {
  const rest = RG_FILE_NUMBER_NUMBERS;
  const length = rules[rest], count = rules[rest + 1];
  const holds_from = Math.min(Math.max(rg_start_file_setting(rules, 0), 0), length - 1);
  for (let i = 0; i < count; i++) into[rules[rest + 2 + i]] = length - holds_from;
}

function rg_start_file_fill_shapes(into, rules) {
  const at = rules[0], full = rules[2], count = rules[3];
  const attack = rg_start_file[at], decay = rg_start_file[at + 1], sustain = rg_start_file[at + 2], release = rg_start_file[at + 3];
  const shaped = !(attack === full && sustain === full && release === 0);
  for (let i = 0; i < count; i++) {
    const shape = rules[4 + i];
    into[shape] = shaped ? 1 : 0;
    into[shape + 1] = shaped ? attack : 0;
    into[shape + 2] = shaped ? decay : 0;
    into[shape + 3] = shaped ? sustain : 0;
    into[shape + 4] = shaped ? release : 0;
  }
}

/* One picture's pixels (rg_runtime.h, rg_start_file_fill_picture). The pixels are the game's own
 * arrays, which JavaScript can write; the C needs the +total+ to copy them first. */
function rg_start_file_fill_picture(rules) {
  const [kind, , start, width, height, turn, across, places_at, colors_at, colors_count, swapped_count, places_by_byte, see_through, row_bytes] = rules;
  const tile_format = RG_FILL_RULES_HEADER_NUMBERS;
  const color_format = tile_format + RG_TILE_FORMAT_NUMBERS;
  const held_places = color_format + RG_COLOR_FORMAT_NUMBERS;
  const held_colors = held_places + (places_at < 0 ? width * height : 0);
  const swapped = held_colors + (colors_at < 0 ? colors_count : 0);
  const pixels = kind === RG_FILL_TILE ? rg_game_tile_pixels : rg_game_image_pixels;
  for (let row = 0; row < height; row++) {
    for (let column = 0; column < width; column++) {
      const from_row = (turn & RG_TURN_UPSIDE_DOWN) ? height - 1 - row : row;
      const from_column = (turn & RG_TURN_MIRRORED) ? width - 1 - column : column;
      const place = places_at < 0 ? rules[held_places + from_row * width + from_column]
        : places_by_byte ? rg_start_file[places_at + from_row * row_bytes + from_column]
          : rg_start_file_place(places_at, rules, tile_format, across, from_row, from_column);
      let color = kind === RG_FILL_TILE ? RG_SEE_THROUGH : -1;
      if (place !== see_through) {
        color = 0;
        if (place < swapped_count) color = rules[swapped + place];
        else if (place < colors_count) color = colors_at < 0 ? rules[held_colors + place] : rg_start_file_color(colors_at, rules, color_format, place);
      }
      pixels[start + row * width + column] = color;
    }
  }
}

/* rg_runtime.c's start_file_signed. */
function rg_start_file_signed(at, width, high_byte_first) {
  const number = rg_start_file_number(at, width, high_byte_first);
  return width === 1 ? (number << 24) >> 24 : (number << 16) >> 16;
}

/* One piece of a pose's frame painted into +places+, behind what is there already (rg_runtime.c's
 * start_file_paint_piece). +frame+ and +tile_format+ are where those layouts start in +rules+. */
function rg_start_file_paint_piece(places, width, height, at, rules, frame, tile_format, origin_x, origin_y, tiles_at, tile_count) {
  const high_byte_first = rules[frame + RG_FRAME_HIGH_BYTE_FIRST_AT], position_bytes = rules[frame + RG_FRAME_POSITION_BYTES_AT];
  const row_tiles = rules[frame + RG_FRAME_ROW_TILES_AT], order = rules[frame + RG_FRAME_TILE_ORDER_AT];
  const flags = rg_start_file_number(at + rules[frame + RG_FRAME_FLAGS_AT], rules[frame + RG_FRAME_FLAGS_BYTES_AT], high_byte_first);
  const left = origin_x + rg_start_file_signed(at + rules[frame + RG_FRAME_X_AT], position_bytes, high_byte_first);
  const top = origin_y + rg_start_file_signed(at + rules[frame + RG_FRAME_Y_AT], position_bytes, high_byte_first);
  let first_tile = rg_start_file_number(at + rules[frame + RG_FRAME_TILE_AT], rules[frame + RG_FRAME_TILE_BYTES_AT], high_byte_first);
  if (rules[frame + RG_FRAME_TILE_BITS_AT] > 0) first_tile &= (1 << rules[frame + RG_FRAME_TILE_BITS_AT]) - 1;
  if (rules[frame + RG_FRAME_TILE_ROW_AT] >= 0) first_tile += rg_start_file[at + rules[frame + RG_FRAME_TILE_ROW_AT]] * row_tiles;
  let columns = 1, rows = 1;
  if (rules[frame + RG_FRAME_SIZE_AT] >= 0) {
    const size = rg_start_file[at + rules[frame + RG_FRAME_SIZE_AT]], mask = (1 << rules[frame + RG_FRAME_SIZE_BITS_AT]) - 1;
    columns = ((size >> rules[frame + RG_FRAME_COLUMNS_BIT_AT]) & mask) + 1;
    rows = ((size >> rules[frame + RG_FRAME_ROWS_BIT_AT]) & mask) + 1;
  } else if (rules[frame + RG_FRAME_BIG_BIT_AT] >= 0 && ((flags >> rules[frame + RG_FRAME_BIG_BIT_AT]) & 1)) {
    columns = 2;
    rows = 2;
  }
  const mirrored = rules[frame + RG_FRAME_MIRRORED_BIT_AT] >= 0 && ((flags >> rules[frame + RG_FRAME_MIRRORED_BIT_AT]) & 1) === 1;
  const upside_down = rules[frame + RG_FRAME_UPSIDE_DOWN_BIT_AT] >= 0 && ((flags >> rules[frame + RG_FRAME_UPSIDE_DOWN_BIT_AT]) & 1) === 1;
  const across = columns * 8, tall = rows * 8;
  for (let y = 0; y < tall; y++) {
    const down = top + y;
    if (down < 0 || down >= height) continue;
    for (let x = 0; x < across; x++) {
      const along = left + x;
      if (along < 0 || along >= width || places[down * width + along] !== 0) continue;
      const from_x = mirrored ? across - 1 - x : x, from_y = upside_down ? tall - 1 - y : y;
      const column = from_x >> 3, row = from_y >> 3;
      const tile = order === RG_FRAME_TILES_DOWN_COLUMNS ? first_tile + column * rows + row
        : order === RG_FRAME_TILES_ACROSS_ROWS ? first_tile + row * columns + column
          : first_tile + row * row_tiles + column;
      if (tile >= tile_count) continue;
      places[down * width + along] = rg_start_file_place(tiles_at + tile * rules[tile_format + RG_TILE_BYTES_AT], rules, tile_format, 1,
        from_y & 7, from_x & 7);
    }
  }
}

/* The pixels of a pose whose pieces are in the file (rg_runtime.h, rg_start_file_fill_pose). */
function rg_start_file_fill_pose(rules) {
  const [kind, , start, width, height, turn, colors_at, colors_count, swapped_count, frame_at, frame_end, given_count, origin_x, origin_y,
    tiles_at, tile_count] = rules;
  const frame = RG_FILL_POSE_HEADER_NUMBERS;
  const tile_format = frame + RG_FRAME_LAYOUT_NUMBERS;
  const color_format = tile_format + RG_TILE_FORMAT_NUMBERS;
  const held_colors = color_format + RG_COLOR_FORMAT_NUMBERS;
  const swapped = held_colors + (colors_at < 0 ? colors_count : 0);
  const piece_bytes = rules[frame + RG_FRAME_PIECE_BYTES_AT];
  let count = given_count, first = frame_at;
  if (count < 0) {
    count = rg_start_file_number(frame_at, rules[frame + RG_FRAME_COUNT_BYTES_AT], rules[frame + RG_FRAME_HIGH_BYTE_FIRST_AT]);
    first += rules[frame + RG_FRAME_COUNT_BYTES_AT];
  }
  count = Math.min(count, Math.floor((frame_end - first) / piece_bytes));
  const places = new Int32Array(width * height);
  for (let piece = 0; piece < count; piece++) {
    rg_start_file_paint_piece(places, width, height, first + piece * piece_bytes, rules, frame, tile_format, origin_x, origin_y, tiles_at,
      tile_count);
  }
  const pixels = kind === RG_FILL_TILE ? rg_game_tile_pixels : rg_game_image_pixels;
  for (let row = 0; row < height; row++) {
    for (let column = 0; column < width; column++) {
      const from_row = (turn & RG_TURN_UPSIDE_DOWN) ? height - 1 - row : row;
      const from_column = (turn & RG_TURN_MIRRORED) ? width - 1 - column : column;
      const place = places[from_row * width + from_column];
      let color = kind === RG_FILL_TILE ? RG_SEE_THROUGH : -1;
      if (place !== 0) {
        color = 0;
        if (place < swapped_count) color = rules[swapped + place];
        else if (place < colors_count) color = colors_at < 0 ? rules[held_colors + place] : rg_start_file_color(colors_at, rules, color_format, place);
      }
      pixels[start + row * width + column] = color;
    }
  }
}

/* The tiles of a background whose map is in the file (rg_runtime.h, rg_start_file_fill_background). */
function rg_start_file_fill_background(rules) {
  const [, start, map_at, cells, across, side, map_high_byte_first, tile_bits, mirror_bit, flip_bit, bank_at, bank_bits, row_tiles,
    tiles_at, tile_count, colors_at, bank_count, bank_size, sets] = rules;
  const tile_format = RG_FILL_BACKGROUND_HEADER_NUMBERS;
  const color_format = tile_format + RG_TILE_FORMAT_NUMBERS;
  const lists = color_format + RG_COLOR_FORMAT_NUMBERS;
  const columns = across * side;
  const tiles_drawn = columns * Math.floor(cells / across) * side;
  const places = new Int32Array(64);
  for (let cell = 0; cell < cells; cell++) {
    const word = rg_start_file_number(map_at + cell * 2, 2, map_high_byte_first);
    const first_tile = word & ((1 << tile_bits) - 1);
    const mirrored = (word >> mirror_bit) & 1, upside_down = (word >> flip_bit) & 1;
    const bank = (word >> bank_at) & ((1 << bank_bits) - 1);
    for (let down = 0; down < side; down++) {
      for (let along = 0; along < side; along++) {
        const tile = first_tile + (upside_down ? side - 1 - down : down) * row_tiles + (mirrored ? side - 1 - along : along);
        const number = (Math.floor(cell / across) * side + down) * columns + (cell % across) * side + along;
        for (let at = 0; at < 64; at++) {
          const row = at >> 3, column = at & 7;
          places[at] = tile < tile_count
            ? rg_start_file_place(tiles_at + tile * rules[tile_format + RG_TILE_BYTES_AT], rules, tile_format, 1,
              upside_down ? 7 - row : row, mirrored ? 7 - column : column)
            : 0;
        }
        for (let set = 0; set < sets; set++) {
          const list = lists + (set * bank_count + bank) * (1 + bank_size);
          const drawn = start + (set * tiles_drawn + number) * 64;
          for (let at = 0; at < 64; at++) {
            let color = 0;
            if (places[at] === 0) color = RG_SEE_THROUGH;
            else if (bank >= bank_count) color = 0;
            else if (rules[list] < 0) color = rules[list + 1 + places[at]];
            else if (rules[list] < bank_count) color = rg_start_file_color(colors_at + rules[list] * bank_size * 2, rules, color_format, places[at]);
            rg_game_tile_pixels[drawn + at] = color;
          }
        }
      }
    }
  }
}
