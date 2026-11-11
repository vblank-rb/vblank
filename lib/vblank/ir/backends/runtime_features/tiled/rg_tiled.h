/* What a game with scenery drawn from tiles calls, and the layout of that scenery as the build
 * writes it (rg_tiled.c). */
#ifndef RG_TILED_H
#define RG_TILED_H

#include <stdint.h>

void rg_background_stamp(int32_t background);
void rg_background_put_up(int32_t background);
/* The start of Reference#take_over: a background coming up as a scene takes over goes up as
 * declared, so the cells the game changed of its name are forgotten before anything is painted. */
void rg_background_forget_cells(int32_t background);
/* Put a background's window at (x, y) of its map, in pixels: the picture slides. Whether it comes
 * round again is the background's (RG_BG_NEVER_WRAPS, below). */
void rg_background_scroll(int32_t background, int32_t x, int32_t y);
/* Reference#exec_place_bar: a status bar's top at a row of the screen. */
void rg_place_bar(int32_t background, int32_t top);
/* Reference#exec_place_bar's +covers+: whether a status bar hides the sprites from its top down. */
void rg_bar_covers(int32_t background, int32_t covers);
/* Reference#exec_box_background: a background shown only inside a box of the screen while +held+ is
 * not 0, and everywhere while it is. */
void rg_background_box(int32_t background, int32_t x, int32_t y, int32_t width, int32_t height, int32_t held);
/* One cell becomes tile number +tile+ of the background's tiles. A cell the map does not have is
 * left alone. */
void rg_background_set_tile(int32_t background, int32_t col, int32_t row, int32_t tile);
/* The same change on a background declared `held: true`: it waits for rg_show_held_tiles. With
 * +most+ changes waiting, every one of them goes in first. +most+ is at most RG_HELD_TILES_ROOM. */
#define RG_HELD_TILES_ROOM 1024
void rg_background_hold_tile(int32_t background, int32_t col, int32_t row, int32_t tile, int32_t most);
/* Every change waiting, in the order the game made them. A background put up forgets them. */
void rg_show_held_tiles(void);
/* Every cell becomes map number +which+ of the background's maps, as it was declared. A number
 * naming none of them leaves the cells alone. */
void rg_background_show_map(int32_t background, int32_t which);
/* Every tile of the background is drawn from now on with step number +which+ of the lists of
 * colors it can be told (RG_BG_COLOR_STEPS of them). A number naming none of them is the colors
 * it was drawn in. */
void rg_background_draw_with(int32_t background, int32_t which);
/* The tiles a background draws from one of several lists it follows show set number +set+ of its
 * tiles from now on. +rules+ is how many tile pixels the game has, the background, how many of its
 * tiles are drawn from the list, and each of those tiles. */
void rg_background_follow(const int32_t *rules, int32_t set);
/* +pivot_x+, +pivot_y+: the point on screen it turns around, which the statement names. */
void rg_background_turn(int32_t background, int32_t angle, int32_t size, int32_t pivot_x, int32_t pivot_y);

/* A BENT BACKGROUND has every line of the screen at its own distance across, on top of where the
 * background is scrolled to (RG_BG_BENT, below). How far is the game's to work out, once a pass
 * for every line, in the gap between frames (Reference#work_out_bends): rg_screen_work_out_bends
 * calls rg_game_work_out_bends there, which hands each bend's lines to rg_bend_work_out in the
 * console's order, and the picture reads what was worked out however often it is painted. For
 * each line rg_bend_work_out calls rg_game_bend_offsets with one background and one line of the
 * screen in mind, and the game answers for the background asked about, after running whatever is in
 * its block first:
 *
 *   if (rg_bend_asked(2)) { row = rg_bend_line(); ...; rg_bend_answer(offset); }
 *
 * The block may change the game's variables, so it runs exactly as often as the interpreter runs
 * it: once for each line of the screen, every pass. Before the first gap every line sits flat, as on the console. Where a
 * bend is written, the game asks for the picture to be built again with
 * rg_screen_request_rebuild. */

void rg_screen_work_out_bends(void);
void rg_bend_work_out(int32_t background, int32_t first_line, int32_t past_line);
int32_t rg_bend_asked(int32_t background);
int32_t rg_bend_line(void);
void rg_bend_answer(int32_t offset);
void rg_game_bend_offsets(void);
void rg_game_work_out_bends(void);

/* Each background is RG_BG_FIELDS numbers in rg_game_backgrounds, in the order the stack draws
 * them. Its scene is the number the game counts that scene by, RG_EVERY_SCENE for scenery every
 * screen shows, or RG_NEVER_ARRIVES for a scene nothing hands the screen over to (so never
 * shown). Its place in the stack is how far forward the layer it named is among the layers the
 * game declared, or RG_NO_LAYER for one that named none.
 *
 * Its maps are entries of rg_game_maps from RG_BG_FIRST_MAP on, the first being the one it shows
 * when the game starts. RG_BG_SHOWABLE_MAPS is how many of them it can be handed while the game
 * runs, which is none for a background declared with one map.
 *
 * A background scrolls over the grid of the map it shows (RG_MAP_GRID_COLS by RG_MAP_GRID_ROWS
 * cells) and its picture comes round again at that grid's edge, unless RG_BG_NEVER_WRAPS is 1:
 * one with a map too big for any grid, or with maps of different sizes, shows nothing past the
 * edge of its map (IR::TileMap).
 *
 * Two scenes may each declare a background by the same name. Each is an entry here with its own
 * maps, and they share what the game does to the name, as the interpreter keeps that by name:
 * the scroll, the turn, the colors it is told, and the run's own copy of the cells. RG_BG_KEPT_BY
 * is the entry that keeps those for the name: the last one the program declares, wherever the
 * stack puts it, and the one every statement naming the background reaches. Its see-through
 * layer is also the one RG_BG_SEE_THROUGH gives every entry of the name.
 *
 * RG_BG_SEE_THROUGH is which see-through layer it is in, counting through rg_game_see_through,
 * or RG_SOLID. RG_BG_BENT is 1 for one the game bends (rg_game_bend_offsets).
 *
 * RG_BG_FADE_PLACE is the furthest forward a placed fade's layer can be and still leave it as
 * drawn, or RG_NO_LAYER when every placed fade reaches it. That is its own place in the stack,
 * unless something else was declared by its name further forward: the interpreter knows what a
 * placed fade leaves alone by name, so the two are left or reached together.
 *
 * Its tiles are RG_BG_TILES pictures in rg_game_tile_pixels from RG_BG_TILES_START on, in the
 * colors they were drawn in. One that can be drawn from other lists of colors has the same
 * pictures again after those, once for each of the RG_BG_COLOR_STEPS steps it can be told, a
 * step swapping the colors by the place each pixel was drawn at.
 *
 * RG_BG_IN_BLOCKS is 1 for one that is drawn in blocks while the picture is shown in them, and 0
 * for one the game leaves as drawn. RG_BG_CAN_TURN is 1 for one declared as able to turn, turned
 * yet or not.
 *
 * RG_BG_PAINTED is RG_NOT_PAINTED for a background with no tile the game paints. For one with
 * any it is where its tiles start in rg_game_painted_tiles, two numbers a tile: the run that
 * paints it and which of the run's tiles it is, or RG_NOT_PAINTED and nought for a tile that is
 * a picture. RG_BG_RUN_COLORS is then where the colors its painted tiles are shown in start in
 * rg_game_run_colors: sixteen for each run the game has, by place, with RG_SEE_THROUGH where a
 * place shows what is behind; and the same again for each step of colors it can be told.
 *
 * RG_BG_BAR_TOP is RG_NOT_A_BAR for a background, and for a status bar the row of the screen it was
 * declared to start at (Nodes::Background#bar_top). A status bar takes no level: it is painted in
 * front of every background and behind every sprite, so its RG_BG_LEVEL is RG_NOT_A_BAR too. */
#define RG_EVERY_SCENE (-1)
#define RG_NEVER_ARRIVES (-2)

#define RG_NOT_A_BAR (-1)
/* The most backgrounds a game may have; the build refuses more. */
#define RG_MAX_BACKGROUNDS 64
enum {
  RG_BG_TILE_W, RG_BG_TILE_H, RG_BG_FIRST_MAP, RG_BG_SHOWABLE_MAPS, RG_BG_KEPT_BY, RG_BG_NEVER_WRAPS,
  RG_BG_TILES_START, RG_BG_SCENE, RG_BG_LEVEL, RG_BG_ON_ARRIVAL, RG_BG_STACK_PLACE,
  RG_BG_SEE_THROUGH, RG_BG_BENT, RG_BG_FADE_PLACE, RG_BG_TILES, RG_BG_COLOR_STEPS, RG_BG_IN_BLOCKS,
  RG_BG_CAN_TURN, RG_BG_PAINTED, RG_BG_RUN_COLORS, RG_BG_BAR_TOP, RG_BG_ABOVE_ROW, RG_BG_FIELDS
};
extern const int32_t rg_game_backgrounds[];
#define RG_NOT_PAINTED (-1)
extern const int32_t rg_game_painted_tiles[];
extern const uint16_t rg_game_run_colors[];

/* Each map is RG_MAP_FIELDS numbers in rg_game_maps: where its cells start in rg_game_map_cells,
 * how many columns and rows it has, and the grid it comes round at (nought each way for a
 * background that never comes round). Its cells are row after row, each the number of a tile or
 * RG_CELL_EMPTY where the map has none. */
#define RG_CELL_EMPTY (-1)
enum { RG_MAP_CELLS, RG_MAP_COLS, RG_MAP_ROWS, RG_MAP_GRID_COLS, RG_MAP_GRID_ROWS, RG_MAP_FIELDS };
extern const int32_t rg_game_maps[];
extern const int16_t rg_game_map_cells[];

extern const int32_t rg_game_always_up[];

#endif
