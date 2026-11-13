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

/* The keys and gamepad buttons the game adds to the window's layout (rg_window_use_game_controls). */
extern const int32_t rg_game_controls[];
/* The most players the build seats (`players:`), 0 for none named: one number (rg_seats.h). */
extern const int32_t rg_game_seats[];

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
 * buttons are numbered in IR::Buttons::NAMES's order — a, b, select, start, right, left, up,
 * down, r, l (the Advance's key register's), then x, y, c — and -1 means any of them. */
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
 * rather than tiles (a picture of up to 256 colours), the place that is see-through (0 for a
 * picture of tiles, -1 for none), and how many bytes of the file are from one row of a picture of
 * bytes to the next (its width, or the width of the wider picture it is a piece of, as a letter is
 * of a strip of them). Then the layout its tiles are kept in, RG_TILE_FORMAT_NUMBERS
 * numbers (Console::TileFormat; the numbers are written ahead of the runtime, Computer::StartFileNumbers): a tile's bytes, how many bit planes, where each plane's first bit
 * is (eight, the unused ones 0), the bits from one row to the next, and where each of the eight
 * columns' bits is, a bit counted through the tile's bytes from bit 0 of the first; and the layout its
 * colours are kept in, RG_COLOR_FORMAT_NUMBERS numbers (Console::ColorFormat): 1 for the high byte
 * first, where red, green and blue are in the two bytes, and how many bits each has. Each is all 0
 * where the game holds that list. Then the game's own places (one for each pixel) where the file has
 * none, its own colours where the file has none, and the other list. A place is the see-through one,
 * or a place in the colours: its fifteen bits, the other list's colour at that place where it has one,
 * and 0 for a place past the colours.
 *
 * rg_start_file_fill_background: the tiles of a background whose map, tiles and colours are all in
 * the file (IR::StartFile::Background), its map in VBlank's own record or as the original's console
 * keeps it, and its tiles and colours as that console keeps them. Which tiles the map
 * names is in the file, so the game holds a tile for every cell of the map, in the map's order, and
 * this fills each: the cell's tile, turned as the cell says, in the colours of the cell's bank.
 * +rules+ are RG_FILL_BACKGROUND_HEADER_NUMBERS numbers: how many tile pixels there are in all,
 * where this background's start, where its map is in the file, how many cells the map has, how many
 * to a row, how many tiles a side a cell is, 1 where a cell's two bytes are high byte first; then
 * how a cell is read (Console::MapWordFormat): how many bits name its tile, the bit for mirrored,
 * the bit for upside down (each a bit past the cell's last, which is never set, for a cell that
 * cannot turn its tile), where its bank starts and how many bits that is (none for a cell whose
 * tiles all draw from the first bank), and how many tiles a
 * row of video memory holds, by which a cell of several tiles finds its lower ones (0 for a cell of
 * one); then where the tiles are in the file and how many, where the colours are, how many banks
 * and how many colours a bank; and how many sets of colours the tiles are written in, the first
 * their own and one more for each step of other colours the background can be told; and how many
 * tiles the game holds for the background before the map's in each set (a stand-in for each bank,
 * and the tiles of the cells it may be written later, which rg_start_file_fill_picture fills), so a
 * cell's tile is that many on from the set's first; and how many bytes a cell is, two, or one for
 * a map of bytes, each a tile's number, as a layer that turns keeps its map, or four for a cell of
 * VBlank's own record (Original::MapCell, lib/vblank/original/map_cell.rb). Then the two
 * layouts, as rg_start_file_fill_picture has them, and for each set each bank's colours: the bank
 * of the file they are, or -1, and then a colour for each place, which the game holds, where it
 * is -1. The tiles of one set follow those of the one before. Place 0 is RG_SEE_THROUGH. A cell
 * naming a tile past the file's draws nothing, and one naming a bank past its colours is drawn in
 * colour 0: the file is the player's, and the game plays on.
 *
 * rg_start_file_fill_followed_tiles: which of such a background's tiles are drawn from one list of
 * colours the game changes, for a background that follows several (rg_background_follow, whose
 * rules +followed+ is: how many tile pixels, the background, how many tiles, and the tiles). The
 * game writes the tiles it holds and leaves room for one for every cell of the map; which bank a
 * cell is of is in the file, so this adds the tile of each cell whose bank has its bit set in
 * +banks+ (bank 0 the lowest bit), and counts them in. +rules+ are the background's own, as
 * rg_start_file_fill_background has them. A cell naming a bank past the colours follows no list.
 *
 * rg_start_file_fill_moving_cells: the cells of such a background that name a tile taking turns
 * through pictures (IR::StartFile::MovingTile), each shown as a tile of a run of tiles the game
 * paints, chosen by the cell's bank and turn. +painted+ is rg_game_painted_tiles, written where it
 * can be. +rules+ are the background's own, as rg_start_file_fill_background has them. +moving+ is:
 * where the background's painted tiles start in +painted+, how many moving tiles, and for each its
 * tile as a cell names it and then, for each bank and each of the four turns (none, mirrored,
 * upside down, both), the run and which of its tiles. A cell naming such a tile in a bank past the
 * colours keeps its own tile.
 *
 * rg_start_file_fill_painted_tiles: +tiles+ tiles of the file into +table+, 32 bytes each, as a run
 * of painted tiles keeps them: two places a byte, the left one in the low four bits.
 * +rules+ are the layout the tiles are kept in, RG_TILE_FORMAT_NUMBERS numbers, then for each tile
 * where it is in the file and how it is turned (RG_TURN_MIRRORED, RG_TURN_UPSIDE_DOWN).
 *
 * rg_start_file_fill_pose: the pixels of a picture that is one frame of the original's sprites
 * (IR::StartFile::Pose): a list of pieces, each saying where it sits from the object's place,
 * which tile it starts at, how it is turned and how many tiles it is each way. The frame is in the
 * file as a record of VBlank's own (Original::FrameRecord, lib/vblank/original/frame_record.rb,
 * which is where its layout is written down), the same whatever the original: the pack's
 * unpacking reads the original's frame and writes the record, so this is told nothing of how an
 * original keeps one. How many
 * pieces there are and what each is is in the file, so the game holds a picture of the size it
 * was given and this paints each piece into it, the earlier in front where two overlap. The frame
 * is painted once, and its pixels written into each copy of the picture the game holds, one for
 * each list of colours it is drawn in. +rules+ are RG_FILL_POSE_HEADER_NUMBERS numbers: what is
 * filled, +total+, how many copies, the picture's width and height and how it is turned once
 * painted, as rg_start_file_fill_picture has them; where its colours are in the file (-1 where the
 * game holds them), how many colours; where the frame's entry is in the file, four
 * bytes saying where its record starts, and where the records start, which that is counted from
 * (0 for a frame with no record); where
 * the object's place is in the picture, across and down; where the tiles are in the file and
 * how many; and the bank a piece must name to be painted (-1 for every piece). Then the two
 * layouts and the game's own colours where the file has none, as rg_start_file_fill_picture has
 * them. Then for each copy: where its pixels start, how many colours of another list it is drawn
 * with, and that list. Place 0 is see-through. The file is the player's, and the game plays on whatever it
 * holds: pieces are read while they end inside the file, a piece or the part of one outside the
 * picture is not painted, and a tile past the file's paints nothing.
 *
 * rg_start_file_put_tile_pixels: +count+ of the game's own pixels, +pixels+, into the background
 * tiles' pixels from +start+ on, of which there are +total+: a tile the game holds for a
 * background whose map is in the file that draws something the file does not fill (a bank's
 * stand-in), in the room rg_screen_tile_pixels_room made for that background's tiles.
 *
 * rg_start_file_fill_colors: +count+ entries of +colors+ from entry +first+ on, each the fifteen
 * bits of a colour of the file, two bytes each from byte +at+ on, kept in the layout +format+
 * (RG_COLOR_FORMAT_NUMBERS numbers, as above). These are the colours that are no part of a
 * picture (IR::StartFile::Color): the game keeps them in an array of its own and reads an entry
 * where a game holding its data writes a colour, as a screen's backdrop does. The colours of a
 * list of colours read from the file are entries of it too (IR::StartFile#colors).
 *
 * rg_start_file_fill_places: +count+ entries of +numbers+ from entry +first+ on, each a byte of the
 * file from byte +at+ on, a place among +places+ colours: a byte past them is place 0. The levels of
 * a shading read from the file (IR::StartFile::Shading), whose colours rg_start_file_fill_colors
 * fills into the same array.
 *
 * rg_start_file_walk_colors: +count+ entries of +colors+ from entry +first+ on, each made from an
 * entry before it (IR::StartFile::WalkedColor): +made+ holds three numbers for each, the entry it
 * is made from, the colour it is walked toward, and how many steps each of its three channels is
 * moved toward that colour's, and no further. It is one step of a walk of a list read from the
 * file, which the build works out itself for a list it holds (Graphics::Color.walked_toward).
 *
 * rg_start_file_count_walk_colors: the same for a walk that waits for a falling count
 * (IR::StartFile::CountedWalkColor): +made+ holds five numbers for each, the entry it is made from,
 * the colour walked from, the step, where the count starts and how many steps
 * (Graphics::Color.counted_walk).
 *
 * rg_start_file_choose_colors: +count+ entries of +colors+ from entry +first+ on, each a colour of
 * a list the file chooses (IR::StartFile::ChosenColor). +rules+ are RG_CHOSEN_COLORS_HEADER_NUMBERS
 * numbers: where a frame's entry is in the file and where the frames' records start, as
 * rg_start_file_fill_pose has them; where the lists' colours are in the file, how many colours a
 * list is, and how many lists there are; and the place of the first entry filled, the next entry
 * being the next place. Then the layout the colours are kept in. The list is the bank the frame's
 * front piece names in its record (RG_PIECE_BANK_AT), bank 0 for a frame with no piece. A console's
 * sprite entry names the bank of colours it is drawn from, so a pose drawn in its frame's bank is
 * drawn in these. The file is the player's: a bank past the lists is colour 0.
 *
 * rg_start_file_frame_bank: that bank itself, of the frame whose entry is at +entry_at+, the
 * frames' records starting at +records_at+: 0 for a frame with no piece. The game writes with it
 * which list a pose drawn in its frame's bank follows (IR::StartFile::Pose#bank_lists).
 *
 * A COLOUR OF SUCH A LIST IS WRITTEN IN THE GAME AS A MARKER wherever the game would hold the
 * colour (IR::StartFile, "MARKERS"): a number of sixteen bits above RG_MARKED_COLOR, never all
 * sixteen, which names entry (marker - RG_MARKED_COLOR - 1) of +colors+.
 * rg_start_file_fill_marked_pixels puts the entry's colour where each marker is among +count+
 * pixels from +start+ on, of the +kind+ of pixels (RG_FILL_TILE or RG_FILL_IMAGE), of which there
 * are +total+. The game calls it once the colours are filled and every picture read from the file
 * is, since one of those drawn in such a list is filled with markers.
 * rg_start_file_fill_marked_numbers does the same among +count+ numbers from +start+ on of +table+,
 * a table of colours of the game's own kept as +kept+ (RG_TABLE_UINT16 or RG_TABLE_INT32): the
 * colour each place of what the game paints as it runs shows (rg_game_run_images,
 * rg_game_run_colors), which the game then writes where it can be written.
 * rg_start_file_marked_color is +color+, or the entry it names where it is a marker, for a colour
 * a statement picks from a table as the game runs.
 *
 * WHAT A RUNTIME FEATURE READS THE FILE BY, for the parts of the file only some games read (a
 * recording's settings, a song part's notes), which the feature fills itself: the file's bytes,
 * and the number +width+ bytes from +at+ in it hold, low byte first, or high byte first where
 * +high_byte_first+ is 1. */
enum { RG_FILL_TILE = 0, RG_FILL_IMAGE = 1 };
enum { RG_TURN_MIRRORED = 1, RG_TURN_UPSIDE_DOWN = 2 };
int rg_start_file_read(const char *path);
void rg_start_file_hand(const uint8_t *bytes, int32_t size);
void rg_start_file_open(const int32_t *rules, const char *missing, const char *wrong_size, const char *wrong_check);
void rg_start_file_fill_table(void *table, int32_t kept, int32_t count, int32_t at, int32_t high_byte_first);
void rg_start_file_fill_bytes(int8_t *samples, int32_t at, int32_t count, int32_t file_at);
void rg_start_file_fill_picture(const int32_t *rules);
void rg_start_file_fill_background(const int32_t *rules);
void rg_start_file_fill_followed_tiles(int32_t *followed, const int32_t *rules, int32_t banks);
void rg_start_file_fill_moving_cells(int32_t *painted, const int32_t *rules, const int32_t *moving);
void rg_start_file_fill_painted_tiles(uint8_t *table, int32_t tiles, const int32_t *rules);
void rg_start_file_fill_pose(const int32_t *rules);
void rg_start_file_put_tile_pixels(int32_t total, int32_t start, int32_t count, const uint16_t *pixels);
void rg_start_file_fill_colors(int32_t *colors, int32_t first, int32_t count, int32_t at, const int32_t *format);
void rg_start_file_fill_places(int32_t *numbers, int32_t first, int32_t count, int32_t at, int32_t places);
void rg_start_file_walk_colors(int32_t *colors, int32_t first, int32_t count, const int32_t *made);
void rg_start_file_count_walk_colors(int32_t *colors, int32_t first, int32_t count, const int32_t *made);
void rg_start_file_choose_colors(int32_t *colors, int32_t first, int32_t count, const int32_t *rules);
int32_t rg_start_file_frame_bank(int32_t entry_at, int32_t records_at);
void rg_start_file_fill_marked_pixels(const int32_t *colors, int32_t kind, int32_t total, int32_t start, int32_t count);
void rg_start_file_fill_marked_numbers(const int32_t *colors, void *table, int32_t kept, int32_t start, int32_t count);
int32_t rg_start_file_marked_color(const int32_t *colors, int32_t color);
const uint8_t *rg_start_file_bytes(void);
uint32_t rg_start_file_number(int32_t at, int32_t width, int32_t high_byte_first);

#endif
