/*
 * Everything the generated game asks of the machine it runs on, and the two things the
 * machine asks of the game.
 *
 * The generated C (game.c) never names SDL, a window or a file. It calls these, and one of two
 * hand-written runtimes answers them: rg_sdl.c, which opens a window, reads the keyboard and
 * plays sound, and rg_headless.c, which has no window at all and is what the tests run. The
 * same game.c links against either.
 */
#ifndef RG_RUNTIME_H
#define RG_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

/* --- what the game provides --- */

/* The whole program, from power-on, a frame at a time: it carries on from where it stopped and
 * gives back 1 when it stops for a frame, 0 when the game is done. Every routine that waits is
 * written so (Computer::Resumable), so between frames the place the game has reached is in its
 * globals. The driver calls it through rg_play_frames. */
int32_t rg_game_main(void);

/* Hands every variable the game keeps to rg_dump_variable, by its Ruby name, and then every
 * list to rg_dump_list — a pool's fields among them, since a pool is kept as lists. */
void rg_game_dump_state(void);

/* The game's name, as VBlank.game was given it: the window's title. */
extern const char rg_game_title[];

/* What the game does when one of its timers ticks. The runtime calls it once for each tick with
 * one timer in mind, and the game runs that timer's handler, if it has one:
 *
 *   if (rg_timer_ticking(0)) { ... }
 */
void rg_game_timer_ticks(void);

/* --- what the runtime provides --- */

/* The end of a frame the game drew. The game then stops for the frame and the driver shows it,
 * reads the buttons and waits for the next. The console calls this moment the vertical blank,
 * which is where the name comes from. */
void rg_wait_vblank(void);

/* Plays the game a frame at a time from power-on: rg_game_main, and the driver's frame between
 * each call, until the game is done. A run that has played all the frames it was asked for ends in
 * the driver's frame. */
void rg_play_frames(void);

/* A routine the runtime asked for an answer waited for a frame, which it cannot: a fault. */
void rg_wait_vblank_while_answering(void);

/* The game stopped on purpose (`halt`). Never comes back. */
_Noreturn void rg_halt(void);

/* `rumble`: the cartridge's motor runs by +pattern+'s eight frames for +frames+ frames, from the
 * next frame on — on a console whose cartridge carries one. rg_motor_on returns whether it runs on
 * the frame shown now. */
void rg_rumble(int32_t frames, int32_t pattern);
int32_t rg_motor_on(void);

/* The game did something the interpreter refuses (pushed onto a full list, read past the end
 * of one): says so, in the words given printf-style, and stops. Never comes back. A program
 * with no window ends with RG_GAME_WENT_WRONG, so whoever started it can tell the game going
 * wrong from the program failing in its own right (Computer::ProgramRun::GAME_WENT_WRONG). */
_Noreturn void rg_fault(const char *format, ...) __attribute__((format(printf, 1, 2)));
#define RG_GAME_WENT_WRONG 3

/* Whether a button is down (held), or went down since the last frame (pressed): 1 or 0. The
 * buttons are numbered in the order the console's key register holds them — a, b, select,
 * start, right, left, up, down, r, l — and -1 means any of them. */
int32_t rg_held(int32_t button);
int32_t rg_pressed(int32_t button);
/* The same for another player (1 to 16, or 0 for any connected player), asking about +mask+, a
 * bit for each button in that numbering. */
int32_t rg_held_by(int32_t player, int32_t mask);
int32_t rg_pressed_by(int32_t player, int32_t mask);
/* How many players are connected now: at least 1. */
int32_t rg_players_connected(void);
/* Which player the person at this machine is, from 1. Only what the game draws may depend on it. */
int32_t rg_local_player(void);
/* The seed machines in one match share for the game's random numbers: nought when the game is played alone. */
int32_t rg_match_seed(void);

/* A GAME'S TIMERS (`timer :beat, per_second: 60`): counters that tick so many times a second,
 * whatever the game is doing. Each has a number of its own. There is no clock here: a frame is
 * the model's sixtieth of a second, as it is for the interpreter, so a running timer gains its
 * rate over +frames_a_second+ ticks at every frame boundary, and its handler runs once for each
 * whole tick it crosses there.
 *
 * Starting a timer starts its count again from nought. Stopping one keeps its count. Its ticks
 * are the whole ticks so far, coming round at 65536 as the console's counter does, and nought
 * for a timer never started. */
#define RG_MAX_TIMERS 32
void rg_timer_start(int32_t timer, int32_t ticks_a_second, int32_t frames_a_second);
void rg_timer_stop(int32_t timer);
int32_t rg_timer_ticks(int32_t timer);
int32_t rg_timer_ticking(int32_t timer);

/* THE CARTRIDGE'S CLOCK (`clock`): one reading of it, by its place in IR::Clock::READINGS —
 * the hour, minute, second, year, month, day and day of the week (0 for Sunday), then whether
 * there is a clock and whether it was set, 1 or 0. Every reading is 0 when either of those two is.
 * Where the time comes from is the driver's to give (rg_driver.h); a run it gives no time to has
 * no clock. A time the game set is added on: how far it is from the clock's own, in whole days
 * and the seconds left over (IR::Clock::OFFSET_DAYS), 0 and 0 in a game that never sets one. */
int32_t rg_clock_reading(int32_t reading, int32_t offset_days, int32_t offset_seconds);

/* Setting the clock (`clock.set_to`): works out how far the time given is from the clock's own,
 * and makes it read as set; rg_clock_kept_days and rg_clock_kept_seconds then hand the two parts
 * of that over — or +current+ back, with no clock to have set. */
void rg_clock_set_to(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second);
int32_t rg_clock_kept_days(int32_t current);
int32_t rg_clock_kept_seconds(int32_t current);

/* One variable's name and value, for whatever the runtime does with them (the headless one
 * prints them, so a test can compare them with the interpreter's). */
void rg_dump_variable(const char *name, int32_t value);

/* One list, the same way. */
struct rg_list;
void rg_dump_list(const struct rg_list *list);

/* Calls a routine picked out of an array of them. The C the backend writes names the function
 * a call goes to, and an entry of an array is not a name, so the entry is handed to this. */
static inline void rg_call_routine(void (*routine)(void)) { routine(); }

/* A FILE THE GAME IS HANDED AS IT STARTS (IR::StartFile). A game built with its data pack left
 * out reads its pack from one, and its unpacking reads the player's copy of the original; the
 * program holds zeros where those numbers go.
 *
 * The driver hands the file over before the game starts: rg_start_file_read reads it from a path
 * (0 when it cannot be read), and rg_start_file_hand takes bytes the driver already holds, copying
 * them. The game's first statement is rg_start_file_open, handed IR::StartFile#rules: +rules+, the
 * file's size in bytes, how many checks, and each check as where it is, how many bytes, and those
 * bytes, which the file must hold there; and the three sentences of rg_start_file_words. It stops
 * the game with rg_fault, in the sentence that fits (rg_start_file_refusal), when no file was handed
 * over or it is not the one the game reads. Then the game fills what it reads
 * from the file, each once:
 *
 * rg_start_file_fill_table: +count+ entries of +table+, kept as +kept+ (RG_TABLE_INT8...), from
 * byte +at+ on, each as wide as that, low byte first, or high byte first where +high_byte_first+ is 1.
 *
 * rg_start_file_fill_bytes: +count+ bytes of +samples+ from index +at+ on, each the file's byte from
 * byte +file_at+ on, as a signed number (a recording's samples).
 *
 * rg_start_file_fill_picture: one picture's pixels, from +rules+, which are numbers: what is filled
 * (RG_FILL_TILE: a background tile's pixels, of which there are +total+, RG_SEE_THROUGH where the
 * layer behind shows; RG_FILL_IMAGE: the pixels of an image a sprite, a blit or a face draws, of
 * which there are +total+, -1 where nothing is drawn), +total+, where the picture's pixels start
 * there, its width and height, how it is turned (RG_TURN_MIRRORED, RG_TURN_UPSIDE_DOWN, or both), how
 * many tiles wide its places are, where in the file its places are (-1 where the game holds them),
 * where its colours are (-1 where the game holds them), how many colours, how many colours of
 * another list it is drawn with, 1 where its places in the file are one byte a pixel row by row
 * rather than tiles (a picture of up to 256 colours), and the place that is see-through (0 for a
 * picture of tiles, -1 for none). Then the layout its tiles are kept in, RG_TILE_FORMAT_NUMBERS
 * numbers (Console::TileFormat; the numbers are written ahead of the runtime, Computer::StartFileNumbers): a tile's bytes, how many bit planes, where each plane's first bit
 * is (four, the unused ones 0), the bits from one row to the next, and where each of the eight
 * columns' bits is, a bit counted through the tile's bytes from bit 0 of the first; and the layout its
 * colours are kept in, RG_COLOR_FORMAT_NUMBERS numbers (Console::ColorFormat): 1 for the high byte
 * first, where red, green and blue are in the two bytes, and how many bits each has. Each is all 0
 * where the game holds that list. Then the game's own places (one for each pixel) where the file has
 * none, its own colours where the file has none, and the other list. A place is the see-through one,
 * or a place in the colours: its fifteen bits, the other list's colour at that place where it has one,
 * and 0 for a place past the colours. */
enum { RG_FILL_TILE = 0, RG_FILL_IMAGE = 1 };
enum { RG_TURN_MIRRORED = 1, RG_TURN_UPSIDE_DOWN = 2 };
int rg_start_file_read(const char *path);
void rg_start_file_hand(const uint8_t *bytes, int32_t size);
void rg_start_file_open(const int32_t *rules, const char *missing, const char *wrong_size, const char *wrong_check);
void rg_start_file_fill_table(void *table, int32_t kept, int32_t count, int32_t at, int32_t high_byte_first);
void rg_start_file_fill_bytes(int8_t *samples, int32_t at, int32_t count, int32_t file_at);
void rg_start_file_fill_picture(const int32_t *rules);

#endif
