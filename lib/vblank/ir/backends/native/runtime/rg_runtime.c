/*
 * What rg_runtime.h promises the game, handed to the driver that started the program (see
 * rg_driver.h). Nothing here knows whether there is a window.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_runtime.h"
#include "rg_console.h"
#include "rg_driver.h"
#include "rg_list.h"
#include "rg_pacing.h"
#include "rg_refusal.h"
#include "rg_screen.h"
#include "rg_sound.h"

const rg_driver *rg_active_driver;

#define ONE_PLAYERS_BUTTONS 0x1FFFu /* thirteen, as IR::Buttons::NAMES has: the Genesis's C is the last */

/* EACH PLAYER'S BUTTONS, a number each, the first player's first (IR::Buttons.masks), a bit a
 * button. The lists are as long as the most players any build reads; only the first +connected+
 * can hold anything, and a player past them holds nothing. */
static uint32_t held[RG_MOST_PLAYERS];    /* buttons down now */
static uint32_t seen[RG_MOST_PLAYERS];    /* ...and at the last frame boundary, to tell a press from a hold */
static uint32_t pressed[RG_MOST_PLAYERS]; /* buttons that went down at the last frame boundary */
static int32_t connected = 1; /* players connected: never fewer than the driver has reported */

/* +count+ players' buttons as held now. A player stays connected once a driver has reported it, and
 * one it leaves out holds nothing, as the Ruby runtime's rg_players_buttons does. */
static void hold_players(int32_t count, const uint32_t *masks) {
  if (count > RG_MOST_PLAYERS) count = RG_MOST_PLAYERS;
  if (count > connected) connected = count;
  for (int32_t player = 0; player < RG_MOST_PLAYERS; player++)
    held[player] = player < count ? masks[player] & ONE_PLAYERS_BUTTONS : 0;
}

/* A button counts as pressed on the one frame it goes down, however long it is then held — the
 * edge the interpreter's read_buttons finds. */
void rg_players_read(int32_t count, const uint32_t *masks) {
  hold_players(count, masks);
  for (int32_t player = 0; player < RG_MOST_PLAYERS; player++) {
    pressed[player] = held[player] & ~seen[player];
    seen[player] = held[player];
  }
}

/* Down before the first frame boundary and not yet seen there, so the first boundary still finds
 * them going down — the interpreter's hold, and the console's keys from power-on. */
void rg_players_held_from_power_on(int32_t count, const uint32_t *masks) { hold_players(count, masks); }

/* The frame the game drew has ended, whoever is driving and whether or not the run stops here. */
void rg_wait_vblank(void) { rg_screen_frame_ended(); }

void rg_play_frames(void) {
  while (rg_game_main()) rg_active_driver->wait_vblank();
}

void rg_wait_vblank_while_answering(void) {
  rg_fault("the game waited for the screen while working out an answer the picture or a timer asked for");
}

/* --- timers (Reference @timers) --- */

/* One timer: whether it has ever been started, whether it is running, its rate, and how far it
 * has ticked since it was last started, in +frames_a_second+-ths of a tick — each frame adds its
 * rate, and the whole ticks are how many whole +frames_a_second+ that comes to. Whole numbers,
 * as the interpreter keeps them (Reference#accrue_timer), so the two cross a whole tick on the
 * same frame; a fraction added each frame lands a hair under a tick on the frame one falls due. */
typedef struct { int32_t started, running, ticks_a_second, frames_a_second; int64_t parts; } game_timer;
static game_timer timers[RG_MAX_TIMERS];

/* How many whole times a timer has ticked since it was started (Reference#whole_overflows). */
static int64_t whole_ticks(const game_timer *timer) { return timer->parts / timer->frames_a_second; }

/* The timers in the order each was first started, which is the order the interpreter walks them
 * in (the order its Hash got them). */
static int32_t timers_started[RG_MAX_TIMERS];
static int32_t timers_started_count;

enum { NO_TIMER = -1 };
static int32_t ticking = NO_TIMER;

static void fault_unless_timer(int32_t timer) {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault("timer number %d is not one of the %d there is room for", (int)timer, RG_MAX_TIMERS);
}

/* Reference#exec_timer_start */
void rg_timer_start(int32_t timer, int32_t ticks_a_second, int32_t frames_a_second) {
  fault_unless_timer(timer);
  if (!timers[timer].started) timers_started[timers_started_count++] = timer;
  timers[timer] = (game_timer){1, 1, ticks_a_second, frames_a_second, 0};
}

/* Reference#exec_timer_stop: a timer never started has nothing to stop. */
void rg_timer_stop(int32_t timer) {
  fault_unless_timer(timer);
  timers[timer].running = 0;
}

/* Reference#timer_ticks */
int32_t rg_timer_ticks(int32_t timer) {
  fault_unless_timer(timer);
  return timers[timer].started ? (int32_t)(whole_ticks(&timers[timer]) % 65536) : 0;
}

int32_t rg_timer_ticking(int32_t timer) { return timer == ticking; }

/* Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
 * handler once for each whole tick crossed. How many that is is settled before the first of them
 * runs, so a handler that stops its own timer, or starts it again, still finishes the ticks this
 * frame crossed. */
static void timers_frame(void) {
  for (int32_t i = 0; i < timers_started_count; i++) {
    game_timer *timer = &timers[timers_started[i]];
    if (!timer->running) continue;
    int64_t before = whole_ticks(timer);
    timer->parts += timer->ticks_a_second;
    int64_t crossed = whole_ticks(timer) - before;
    ticking = timers_started[i];
    for (int64_t tick = 0; tick < crossed; tick++) rg_game_timer_ticks();
    ticking = NO_TIMER;
  }
}

/* --- the cartridge's clock (Reference#value_of_clock) --- */

/* The readings in IR::Clock::READINGS's order, which is the number the game asks by. Nothing ties
 * the two together but the native run of test_clock.rb, which reads every one of them. */
enum { CLOCK_HOUR, CLOCK_MINUTE, CLOCK_SECOND, CLOCK_YEAR, CLOCK_MONTH, CLOCK_DAY, CLOCK_WEEKDAY, CLOCK_PRESENT, CLOCK_SET };

#define SECONDS_A_DAY 86400

static int32_t clock_present;
static int32_t clock_set;
static int32_t clock_counts_frames; /* moved on a frame at each boundary, rather than told the time */
static int64_t clock_seconds;       /* the time now, as seconds from the start of 1970... */
static int64_t clock_ticks;         /* ...and the console's ticks into the next second */

/* 1 January 2000, in days from the start of 1970: the day a clock that keeps no date reads as
 * starting on. */
#define UNDATED_FIRST_DAY 10957

/* Division that rounds down rather than towards nothing, so a moment before 1970 lands on the
 * day it is in. */
static int64_t floor_div(int64_t a, int64_t b) { return a / b - (a % b != 0 && (a < 0) != (b < 0)); }

/* A CHIP THAT KEEPS NO DATE (RG_CLOCK_KEEPS_DATE 0, the Color's; IR::Clock.undated) counts only
 * the days and the time of day since it started, taken as that many days on from 1 January 2000:
 * so it starts on that day, at the time of day it was started at. */
void rg_clock_starts_at(int64_t seconds, int64_t ticks, int32_t set) {
  clock_present = 1;
  clock_set = set != 0;
  clock_counts_frames = 1;
  clock_seconds = RG_CLOCK_KEEPS_DATE ? seconds
                                      : (int64_t)UNDATED_FIRST_DAY * SECONDS_A_DAY + (seconds - floor_div(seconds, SECONDS_A_DAY) * SECONDS_A_DAY);
  clock_ticks = ticks;
}

/* The days from the start of 1970 to a date, and back. A calendar of plain arithmetic rather than
 * the C library's, which would bring the computer's time zone into it: every fourth year a leap
 * year, but not every hundredth, but every four hundredth. The year is counted from March, so
 * the leap day falls at the end of it, and the counting goes in whole 400-year cycles, which
 * always hold the same number of days. */
static int64_t days_from_date(int64_t year, int64_t month, int64_t day) {
  year -= month <= 2;
  int64_t era = floor_div(year, 400);
  int64_t year_of_era = year - era * 400;
  int64_t day_of_year = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
  int64_t day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
  return era * 146097 + day_of_era - 719468;
}

static void date_from_days(int64_t days, int64_t *year, int32_t *month, int32_t *day) {
  days += 719468;
  int64_t era = floor_div(days, 146097);
  int64_t day_of_era = days - era * 146097;
  int64_t year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
  int64_t day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
  int64_t from_march = (5 * day_of_year + 2) / 153;
  *day = (int32_t)(day_of_year - (153 * from_march + 2) / 5 + 1);
  *month = (int32_t)(from_march < 10 ? from_march + 3 : from_march - 9);
  *year = year_of_era + era * 400 + (*month <= 2);
}

void rg_clock_reads(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second) {
  clock_present = 1;
  clock_set = 1;
  clock_counts_frames = 0;
  clock_seconds = days_from_date(year, month, day) * SECONDS_A_DAY + hour * 3600 + minute * 60 + second;
  clock_ticks = 0;
}

/* A frame of the console's later: as many of its clock's ticks as it takes to draw one
 * (RG_CONSOLE_TICKS_A_FRAME, from rg_console.h), close to a sixtieth of a second. */
static void clock_frame(void) {
  if (!clock_counts_frames) return;
  clock_ticks += RG_CONSOLE_TICKS_A_FRAME;
  clock_seconds += clock_ticks / RG_CONSOLE_TICKS_A_SECOND;
  clock_ticks %= RG_CONSOLE_TICKS_A_SECOND;
}

/* A chip that keeps no date has no date of its own to give, so it reads as never set until the
 * game has set a time on it: an offset of anything but nought (IR::Clock.undated_set?). */
int32_t rg_clock_reading(int32_t reading, int32_t offset_days, int32_t offset_seconds) {
  if (!clock_present) return 0;
  if (reading == CLOCK_PRESENT) return 1;
  if (!clock_set) return 0;
  if (!RG_CLOCK_KEEPS_DATE && offset_days == 0 && offset_seconds == 0) return 0;
  if (reading == CLOCK_SET) return 1;

  int64_t now = clock_seconds + (int64_t)offset_days * SECONDS_A_DAY + offset_seconds;
  int64_t days = floor_div(now, SECONDS_A_DAY);
  int64_t into_day = now - days * SECONDS_A_DAY;
  int64_t year;
  int32_t month, day;
  date_from_days(days, &year, &month, &day);
  switch (reading) {
  case CLOCK_HOUR: return (int32_t)(into_day / 3600);
  case CLOCK_MINUTE: return (int32_t)(into_day / 60 % 60);
  case CLOCK_SECOND: return (int32_t)(into_day % 60);
  case CLOCK_YEAR: return (int32_t)year;
  case CLOCK_MONTH: return month;
  case CLOCK_DAY: return day;
  case CLOCK_WEEKDAY: return (int32_t)(days + 4 - floor_div(days + 4, 7) * 7); /* 1 January 1970 was a Thursday */
  default: rg_fault("the clock has no reading numbered %d", (int)reading);
  }
}

/* SETTING THE CLOCK (Reference#exec_set_clock): how far the time set is from the clock's own, to
 * the whole second, in days and the seconds left over, kept here until the game takes the two
 * parts into its saved numbers (rg_clock_kept_days and rg_clock_kept_seconds). The clock itself is never changed — in a
 * window it is the computer's — and from then on it reads as set. */
static int32_t clock_kept_days;
static int32_t clock_kept_seconds;

void rg_clock_set_to(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second) {
  if (!clock_present) return;
  int64_t today = floor_div(clock_seconds, SECONDS_A_DAY);
  int64_t days = days_from_date(year, month, day) - today;
  int64_t seconds = hour * 3600 + minute * 60 + second - (clock_seconds - today * SECONDS_A_DAY);
  if (seconds < 0) {
    seconds += SECONDS_A_DAY;
    days -= 1;
  }
  clock_kept_days = (int32_t)days;
  clock_kept_seconds = (int32_t)seconds;
  clock_set = 1;
}

/* The days and the seconds rg_clock_set_to kept — or +current+, the game's own number as it was,
 * with no clock to have set. */
int32_t rg_clock_kept_days(int32_t current) { return clock_present ? clock_kept_days : current; }
int32_t rg_clock_kept_seconds(int32_t current) { return clock_present ? clock_kept_seconds : current; }

/* --- the motor (Reference#exec_rumble, #step_motor) --- */

/* THE CARTRIDGE'S MOTOR, which shakes the player's hands: on a console whose cartridge carries
 * one, it runs on or off each frame by an eight-frame pattern, for the frames the game set. A
 * desktop or a web page shakes nothing yet, but the motor is kept all the same, so a test can
 * ask whether it runs. The pattern is read as IR::Rumble reads it: turned a place to the right
 * each frame, and on where its lowest bit is 1. */
static int32_t rumble_left, rumble_bits, motor_on;

void rg_rumble(int32_t frames, int32_t pattern) {
  if (!RG_CONSOLE_RUMBLES) return;
  rumble_left = frames < 0 ? 0 : frames > 0xFFFF ? 0xFFFF : frames;
  rumble_bits = pattern & 0xFF;
}

static void motor_frame(void) {
  if (rumble_left <= 0) {
    motor_on = 0;
    return;
  }
  rumble_bits = ((rumble_bits >> 1) | (rumble_bits << 7)) & 0xFF;
  motor_on = rumble_bits & 1;
  rumble_left--;
}

int32_t rg_motor_on(void) { return motor_on; }

/* The middle of Reference#advance_frame, in its order: the picture is switched on, the timers
 * tick, and then the sound moves on. */
void rg_frame_begins(void) {
  rg_screen_frame_started();
  timers_frame();
  /* The interpreter's order (Reference#advance_frame): the mix, then the tune, then every
   * sounding note's shape (the sound features', in that order), and then the frame is counted,
   * which moves a clock started at a test's moment. */
  rg_sound_frame();
  motor_frame();
  clock_frame();
}

/* A driver's halt and fault never come back; abort() is only there to say so to the compiler.
 * A game that halts stops the motor (Reference#exec_halt). */
_Noreturn void rg_halt(void) {
  rumble_left = 0;
  motor_on = 0;
  rg_active_driver->halt();
  abort();
}

_Noreturn void rg_fault(const char *format, ...) {
  va_list args;
  va_start(args, format);
  rg_active_driver->fault(format, args);
  va_end(args);
  abort();
}

void rg_dump_variable(const char *name, int32_t value) { rg_active_driver->dump_variable(name, value); }

void rg_dump_list(const struct rg_list *list) {
  if (rg_active_driver->dump_list) rg_active_driver->dump_list(list);
}

/* A button's bit in +buttons+, or any of the first player's for -1. */
static int32_t button_down(uint32_t buttons, int32_t button) {
  if (button < 0) return (buttons & ONE_PLAYERS_BUTTONS) != 0;
  return (int32_t)((buttons >> button) & 1u);
}

int32_t rg_held(int32_t button) { return button_down(held[0], button); }
int32_t rg_pressed(int32_t button) { return button_down(pressed[0], button); }

/* Whether any of the buttons in +mask+ is down for +player+ (1 and up), or for any connected
 * player for 0, for a test that names a player. */
static int32_t down_by(const uint32_t *buttons, int32_t player, int32_t mask) {
  if (player == 0) {
    for (int32_t each = 0; each < connected; each++)
      if (buttons[each] & (uint32_t)mask) return 1;
    return 0;
  }
  if (player < 1 || player > RG_MOST_PLAYERS) return 0;
  return (buttons[player - 1] & (uint32_t)mask) != 0;
}

int32_t rg_held_by(int32_t player, int32_t mask) { return down_by(held, player, mask); }
int32_t rg_pressed_by(int32_t player, int32_t mask) { return down_by(pressed, player, mask); }

/* How many players are connected now. */
int32_t rg_players_connected(void) { return connected; }

/* Which player the person at this machine is: the first, until a match names another. */
int32_t rg_local_player(void) { return 1; }

/* The match's shared seed: nought, since the desktop build plays no match yet. */
int32_t rg_match_seed(void) { return 0; }

/* THE FILE THE GAME IS HANDED AS IT STARTS (see rg_runtime.h): its bytes, a copy of the
 * driver's, or none yet. */
static uint8_t *start_file;
static int32_t start_file_size = -1;

void rg_start_file_hand(const uint8_t *bytes, int32_t size) {
  free(start_file);
  start_file = malloc(size > 0 ? (size_t)size : 1);
  if (!start_file) rg_fault("there is no room for the %d bytes of the file handed to the game", (int)size);
  if (size > 0) memcpy(start_file, bytes, (size_t)size);
  start_file_size = size;
}

int rg_start_file_read(const char *path) {
  FILE *file = fopen(path, "rb");
  if (!file) return 0;
  uint8_t *bytes = NULL;
  size_t size = 0;
  size_t room = 0;
  int ok = 1;
  for (;;) {
    if (size == room) {
      room = room ? room * 2 : 65536;
      uint8_t *more = realloc(bytes, room);
      if (!more) {
        ok = 0;
        break;
      }
      bytes = more;
    }
    size_t got = fread(bytes + size, 1, room - size, file);
    size += got;
    if (got == 0) break;
  }
  if (ferror(file) || size > INT32_MAX) ok = 0;
  fclose(file);
  if (ok) rg_start_file_hand(bytes, (int32_t)size);
  free(bytes);
  return ok;
}

void rg_start_file_open(const int32_t *rules, const char *missing, const char *wrong_size, const char *wrong_check) {
  char words[RG_WORDS_ROOM];
  rg_start_file_words sentences = {missing, wrong_size, wrong_check};
  if (rg_start_file_refusal(start_file_size < 0 ? NULL : start_file, start_file_size, rules, &sentences, words, sizeof words))
    rg_fault("%s", words);
}

/* The number +width+ bytes from +at+ in the file hold, low byte first, or high byte first where
 * +high_byte_first+ is 1. */
static uint32_t start_file_number(int32_t at, int32_t width, int32_t high_byte_first) {
  uint32_t number = 0;
  for (int32_t i = 0; i < width; i++) number = (number << 8) | start_file[at + (high_byte_first ? i : width - 1 - i)];
  return number;
}

void rg_start_file_fill_table(void *table, int32_t kept, int32_t count, int32_t at, int32_t high_byte_first) {
  for (int32_t i = 0; i < count; i++) {
    switch (kept) {
    case RG_TABLE_INT8: ((int8_t *)table)[i] = (int8_t)start_file_number(at + i, 1, high_byte_first); break;
    case RG_TABLE_UINT8: ((uint8_t *)table)[i] = (uint8_t)start_file_number(at + i, 1, high_byte_first); break;
    case RG_TABLE_INT16: ((int16_t *)table)[i] = (int16_t)start_file_number(at + (i * 2), 2, high_byte_first); break;
    case RG_TABLE_UINT16: ((uint16_t *)table)[i] = (uint16_t)start_file_number(at + (i * 2), 2, high_byte_first); break;
    default: ((int32_t *)table)[i] = (int32_t)start_file_number(at + (i * 4), 4, high_byte_first); break;
    }
  }
}

/* The place of the pixel at +row+ and +column+ of a picture read from the file: +across+ tiles
 * wide, from +places_at+ on, each tile kept in the layout set at +tile+ (rg_runtime.h, RG_TILE_FORMAT_NUMBERS):
 * bit +plane+ of the pixel is the bit plane_bits[plane] + row * row_bits + column_bits[column] of
 * the tile (IR::FormatReading.place). */
static int32_t start_file_place(int32_t places_at, const int32_t *tile, int32_t across, int32_t row, int32_t column) {
  int32_t tile_bytes = tile[RG_TILE_BYTES_AT], planes = tile[RG_TILE_PLANES_AT], row_bits = tile[RG_TILE_ROW_BITS_AT];
  int32_t start = places_at + ((((row / 8) * across) + (column / 8)) * tile_bytes);
  int32_t place = 0;
  for (int32_t plane = 0; plane < planes; plane++) {
    int32_t bit = tile[RG_TILE_PLANE_BITS_AT + plane] + ((row % 8) * row_bits) + tile[RG_TILE_COLUMN_BITS_AT + (column % 8)];
    place |= ((start_file[start + (bit / 8)] >> (bit % 8)) & 1) << plane;
  }
  return place;
}

/* The channel at bit +at+ of a colour kept as +kept+, +bits+ wide, widened to five bits by repeating
 * its top bits (IR::FormatReading.channel). */
static int32_t start_file_channel(uint32_t kept, int32_t at, int32_t bits) {
  int32_t level = (int32_t)((kept >> at) & ((1u << bits) - 1u));
  return bits >= 5 ? level : (level << (5 - bits)) | (level >> ((2 * bits) - 5));
}

/* Colour +place+ of the colours from +colors_at+ on, kept in the layout set at +format+ (rg_runtime.h,
 * RG_COLOR_FORMAT_NUMBERS), as fifteen bits (IR::FormatReading.colors). */
static uint16_t start_file_color(int32_t colors_at, const int32_t *format, int32_t place) {
  uint32_t kept = start_file_number(colors_at + (place * 2), 2, format[RG_COLOR_HIGH_BYTE_FIRST_AT]);
  int32_t bits = format[RG_COLOR_CHANNEL_BITS_AT];
  return (uint16_t)(start_file_channel(kept, format[RG_COLOR_RED_AT], bits) |
                    (start_file_channel(kept, format[RG_COLOR_GREEN_AT], bits) << 5) |
                    (start_file_channel(kept, format[RG_COLOR_BLUE_AT], bits) << 10));
}

void rg_start_file_fill_picture(const int32_t *rules) {
  int32_t kind = rules[0], total = rules[1], start = rules[2], width = rules[3], height = rules[4];
  int32_t turn = rules[5], across = rules[6], places_at = rules[7], colors_at = rules[8];
  int32_t colors_count = rules[9], swapped_count = rules[10], places_by_byte = rules[11], see_through = rules[12];
  const int32_t *tile_format = rules + RG_FILL_RULES_HEADER_NUMBERS;
  const int32_t *color_format = tile_format + RG_TILE_FORMAT_NUMBERS;
  const int32_t *held_places = color_format + RG_COLOR_FORMAT_NUMBERS;
  const int32_t *held_colors = held_places + (places_at < 0 ? width * height : 0);
  const int32_t *swapped = held_colors + (colors_at < 0 ? colors_count : 0);
  uint16_t *tile_pixels = kind == RG_FILL_TILE ? rg_screen_tile_pixels_to_fill(total) : NULL;
  int16_t *image_pixels = kind == RG_FILL_TILE ? NULL : rg_screen_image_pixels_to_fill(total);
  for (int32_t row = 0; row < height; row++) {
    for (int32_t column = 0; column < width; column++) {
      int32_t from_row = (turn & RG_TURN_UPSIDE_DOWN) ? height - 1 - row : row;
      int32_t from_column = (turn & RG_TURN_MIRRORED) ? width - 1 - column : column;
      int32_t place = places_at < 0     ? held_places[(from_row * width) + from_column]
                      : places_by_byte ? start_file[places_at + (from_row * width) + from_column]
                                       : start_file_place(places_at, tile_format, across, from_row, from_column);
      uint16_t color = 0xFFFFu;
      if (place != see_through) {
        color = 0;
        if (place < swapped_count) {
          color = (uint16_t)swapped[place];
        } else if (place < colors_count) {
          color = colors_at < 0 ? (uint16_t)held_colors[place] : start_file_color(colors_at, color_format, place);
        }
      }
      if (tile_pixels) tile_pixels[start + (row * width) + column] = color;
      else image_pixels[start + (row * width) + column] = (int16_t)color;
    }
  }
}
