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

/* The whole screen the window shows, and where the game's screen sits in it. They are the game's
 * screen and (0, 0) but where the game's screen is shown in the middle of a bigger one, with a
 * border round it (Console::Description#bordered?, a Game Boy Color's screen on the Advance). */
#ifndef RG_WHOLE_WIDTH
#define RG_WHOLE_WIDTH RG_SCREEN_WIDTH
#endif
#ifndef RG_WHOLE_HEIGHT
#define RG_WHOLE_HEIGHT RG_SCREEN_HEIGHT
#endif
#ifndef RG_GAME_LEFT
#define RG_GAME_LEFT 0
#endif
#ifndef RG_GAME_TOP
#define RG_GAME_TOP 0
#endif
#define RG_SCREEN_BORDERED (RG_WHOLE_WIDTH != RG_SCREEN_WIDTH || RG_WHOLE_HEIGHT != RG_SCREEN_HEIGHT)

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

/* The rows of the screen the picture shows, the first and the one past the last; the rest are given
 * up and show black (`screen :bitmap, shown_rows:`, Console::Description#shown_rows). */
#ifndef RG_SHOWN_FIRST_ROW
#define RG_SHOWN_FIRST_ROW 0
#endif
#ifndef RG_SHOWN_PAST_ROW
#define RG_SHOWN_PAST_ROW RG_SCREEN_HEIGHT
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

/* Whether the console's sound chip plays each of the game's voices as a loop it reads out of sound
 * memory, as the PlayStation's does (rg_spu.c; Console::Description#voices_read_sound_memory), rather
 * than making a square wave, a waveform and a hiss itself, as the Game Boy family's do. */
#ifndef RG_VOICES_READ_SOUND_MEMORY
#define RG_VOICES_READ_SOUND_MEMORY 0
#endif

/* How many pieces of sprites the console draws on one line of the screen, the rest of the line's
 * left out, or 0 where every piece is drawn (Console::Description#sprite_pieces_drawn_a_line). */
#ifndef RG_SPRITE_PIECES_A_LINE
#define RG_SPRITE_PIECES_A_LINE 0
#endif

/* Of those, how many slivers eight pixels wide it fetches, from the piece furthest back, or 0 where
 * it counts none (Console::Description#sprite_slivers_drawn_a_line); and how many pixels it draws,
 * from the front, each piece spending its whole width, or 0 where it counts none
 * (Console::Description#sprite_pixels_drawn_a_line). */
#ifndef RG_SPRITE_SLIVERS_A_LINE
#define RG_SPRITE_SLIVERS_A_LINE 0
#endif
#ifndef RG_SPRITE_PIXELS_A_LINE
#define RG_SPRITE_PIXELS_A_LINE 0
#endif

/* How many pieces of sprites the console's sprite table holds, the pieces furthest back left out
 * of every line once it is full, or 0 where every piece is drawn
 * (Console::Description#sprite_pieces_drawn_a_screen). */
#ifndef RG_SPRITE_PIECES_A_SCREEN
#define RG_SPRITE_PIECES_A_SCREEN 0
#endif

/* Whether the console's cartridge fills that table from the piece furthest back, so a full table
 * leaves out the pieces in front, rather than front-most first
 * (Console::Description#sprite_table_filled_from). */
#ifndef RG_SPRITE_TABLE_FROM_BACK
#define RG_SPRITE_TABLE_FROM_BACK 0
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

/* Every button of one player, a bit each (IR::Buttons::EVERY_BUTTON_MASK): what the runtime keeps of
 * a player's number. Every build writes it; this is the same number for a file of the runtime read
 * on its own, and a test holds it to the one every build writes. */
#ifndef RG_ONE_PLAYERS_BUTTONS
#define RG_ONE_PLAYERS_BUTTONS 8191
#endif

/* Where each number of a picture's tile and colour layouts sits in
 * the rules a start-file fill is handed (Computer::StartFileNumbers, which writes them into every
 * build). These are the same numbers, for a file of the runtime read on its own, as an editor's
 * checker reads it; a test holds them to StartFileNumbers.names.
 *
 * A FRAME OF A SPRITE IN THE FILE is a record of VBlank's own, one layout whatever the original.
 * lib/vblank/original/frame_record.rb (Original::FrameRecord) is where that layout is written
 * down, and the RG_FRAME_ and RG_PIECE_ numbers are its own, written into every build from there.
 * Every number is low byte first. A frame is RG_FRAME_HEADER_BYTES, the pieces it holds and the
 * pieces the original names, two bytes each, then RG_FRAME_PIECE_BYTES a piece: x and y from the
 * object's place, two bytes each and signed; its first tile, two bytes; how many tiles on the tile
 * one column to the right is, and the tile one row down, two bytes each; how many tiles it is
 * across and down, a byte each; how it is turned, a byte of RG_PIECE_MIRRORED and
 * RG_PIECE_UPSIDE_DOWN; and, at RG_PIECE_BANK_AT, which bank of the original's colours it is drawn
 * from, two bytes. */
#ifndef RG_TILE_BYTES_AT
#define RG_FILL_POSE_HEADER_NUMBERS 17
#define RG_CHOSEN_COLORS_HEADER_NUMBERS 6
#define RG_FRAME_ENTRY_BYTES 4
#define RG_FRAME_HEADER_BYTES 4
#define RG_FRAME_PIECE_BYTES 16
#define RG_PIECE_X_AT 0
#define RG_PIECE_Y_AT 2
#define RG_PIECE_TILE_AT 4
#define RG_PIECE_COLUMN_STEP_AT 6
#define RG_PIECE_ROW_STEP_AT 8
#define RG_PIECE_COLUMNS_AT 10
#define RG_PIECE_ROWS_AT 11
#define RG_PIECE_TURNS_AT 12
#define RG_PIECE_BANK_AT 14
#define RG_PIECE_MIRRORED 1
#define RG_PIECE_UPSIDE_DOWN 2
#define RG_TILE_BYTES_AT 0
#define RG_TILE_PLANES_AT 1
#define RG_TILE_PLANE_BITS_AT 2
#define RG_TILE_ROW_BITS_AT 10
#define RG_TILE_COLUMN_BITS_AT 11
#define RG_TILE_FORMAT_NUMBERS 19
#define RG_COLOR_HIGH_BYTE_FIRST_AT 0
#define RG_COLOR_RED_AT 1
#define RG_COLOR_GREEN_AT 2
#define RG_COLOR_BLUE_AT 3
#define RG_COLOR_CHANNEL_BITS_AT 4
#define RG_COLOR_FORMAT_NUMBERS 5
#define RG_FILL_RULES_HEADER_NUMBERS 14
#define RG_FILL_BACKGROUND_HEADER_NUMBERS 24
#define RG_MARKED_COLOR 32768
#endif

#endif
