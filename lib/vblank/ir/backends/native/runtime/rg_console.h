/*
 * The console a game is built as: how big its screen is, and how its clock counts a frame.
 *
 * A game names the consoles it is for, and the C is built as one of them (Computer::ConsoleNumbers
 * writes its numbers into rg_console_numbers.h, beside game.c). The runtime's screen buffers are
 * that size, its window shows that many pixels, and its frames last as long as that console's.
 * Where no such file is beside it — the small C programs the native tests build around one
 * header — it is the Game Boy Advance.
 */
#ifndef RG_CONSOLE_H
#define RG_CONSOLE_H

#if __has_include("rg_console_numbers.h")
#include "rg_console_numbers.h"
#endif

#ifndef RG_SCREEN_WIDTH
#define RG_SCREEN_WIDTH 240
#endif
#ifndef RG_SCREEN_HEIGHT
#define RG_SCREEN_HEIGHT 160
#endif

/* How many bits of each colour channel the console shows, from the top. */
#ifndef RG_COLOR_BITS
#define RG_COLOR_BITS 5
#endif

/* The console's own clock, and how many of its ticks one frame — a picture drawn and the gap
 * after it — takes. Together they are how long a frame is; no console shows exactly sixty a
 * second. */
#ifndef RG_CONSOLE_TICKS_A_SECOND
#define RG_CONSOLE_TICKS_A_SECOND 16777216
#endif
#ifndef RG_CONSOLE_TICKS_A_FRAME
#define RG_CONSOLE_TICKS_A_FRAME 280896
#endif

/* Whether the console's display can mix the finished picture toward a colour as it draws it. One
 * that cannot has every fade and tint mixed into its colour tables instead
 * (Console::Description#blends). */
#ifndef RG_CONSOLE_DIMS
#define RG_CONSOLE_DIMS 0
#endif
#ifndef RG_CONSOLE_BLENDS
#define RG_CONSOLE_BLENDS 1
#endif

/* How many pieces of sprites the console draws on one line of the screen, the rest of the line's
 * left out, or 0 where every piece is drawn (Console::Description#sprite_pieces_drawn_a_line). */
#ifndef RG_SPRITE_PIECES_A_LINE
#define RG_SPRITE_PIECES_A_LINE 0
#endif

/* Whether the console's cartridge carries a motor that a game's `rumble` runs
 * (Console::Description#rumbles). */
#ifndef RG_CONSOLE_RUMBLES
#define RG_CONSOLE_RUMBLES 0
#endif

/* Whether the clock chip its cartridges carry holds the date, or only counts the days and the
 * time of day since it started (Console::Description#clock_keeps_date). */
#ifndef RG_CLOCK_KEEPS_DATE
#define RG_CLOCK_KEEPS_DATE 1
#endif

/* Whether the window plays the console's own start-up before the game, from the player's BIOS where
 * the player has one (rg_bios_boot.h; Console::Description#plays_bios_start_up). The desktop build of
 * such a console writes the start of the game's cartridge beside game.c for the BIOS to read
 * (rg_cartridge_start.h). */
#ifndef RG_CONSOLE_PLAYS_BIOS_START_UP
#define RG_CONSOLE_PLAYS_BIOS_START_UP 0
#endif

/* Where each number of a picture's tile and colour layouts, and of a pose's frame layout, sits in
 * the rules a start-file fill is handed (Computer::StartFileNumbers, which writes them into every
 * build). These are the same numbers, for a file of the runtime read on its own, as an editor's
 * checker reads it; a test holds them to StartFileNumbers::NAMES. */
#ifndef RG_TILE_BYTES_AT
#define RG_FILL_POSE_HEADER_NUMBERS 16
#define RG_FRAME_PIECE_BYTES_AT 0
#define RG_FRAME_COUNT_BYTES_AT 1
#define RG_FRAME_HIGH_BYTE_FIRST_AT 2
#define RG_FRAME_X_AT 3
#define RG_FRAME_Y_AT 4
#define RG_FRAME_POSITION_BYTES_AT 5
#define RG_FRAME_TILE_AT 6
#define RG_FRAME_TILE_BYTES_AT 7
#define RG_FRAME_TILE_BITS_AT 8
#define RG_FRAME_TILE_ROW_AT 9
#define RG_FRAME_ROW_TILES_AT 10
#define RG_FRAME_FLAGS_AT 11
#define RG_FRAME_FLAGS_BYTES_AT 12
#define RG_FRAME_MIRRORED_BIT_AT 13
#define RG_FRAME_UPSIDE_DOWN_BIT_AT 14
#define RG_FRAME_BIG_BIT_AT 15
#define RG_FRAME_SIZE_AT 16
#define RG_FRAME_COLUMNS_BIT_AT 17
#define RG_FRAME_ROWS_BIT_AT 18
#define RG_FRAME_SIZE_BITS_AT 19
#define RG_FRAME_TILE_ORDER_AT 20
#define RG_FRAME_LAYOUT_NUMBERS 21
#define RG_FRAME_TILES_DOWN_COLUMNS 1
#define RG_FRAME_TILES_ACROSS_ROWS 2
#define RG_TILE_BYTES_AT 0
#define RG_TILE_PLANES_AT 1
#define RG_TILE_PLANE_BITS_AT 2
#define RG_TILE_ROW_BITS_AT 6
#define RG_TILE_COLUMN_BITS_AT 7
#define RG_TILE_FORMAT_NUMBERS 15
#define RG_COLOR_HIGH_BYTE_FIRST_AT 0
#define RG_COLOR_RED_AT 1
#define RG_COLOR_GREEN_AT 2
#define RG_COLOR_BLUE_AT 3
#define RG_COLOR_CHANNEL_BITS_AT 4
#define RG_COLOR_FORMAT_NUMBERS 5
#define RG_FILL_RULES_HEADER_NUMBERS 14
#define RG_FILL_BACKGROUND_HEADER_NUMBERS 20
#define RG_MARKED_COLOR 32768
#endif

#endif
