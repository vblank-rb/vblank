/*
 * SCENERY DRAWN FROM TILES (Reference @bg_shown and the rest): backgrounds and status bars, the
 * maps they show and the cells the game changes, their scroll, turn, bends and boxes, the order a
 * stack of layers puts them in, and a scene's scenery coming down. A runtime feature
 * (backends/runtime_features.rb): this file is included at the end of rg_screen.c, for a game
 * that declares a background, so it reads the screen's own state and painters as if it were
 * written there. A game with none builds without it.
 */
#include "rg_tiled.h"

static int32_t background_field(int32_t background, int32_t field) {
  return rg_game_backgrounds[background * RG_BG_FIELDS + field];
}

static int32_t showing(int32_t background);
static int32_t bar_showing(void);

/* A background is painted onto a sheet of its own first when it is laid on the picture a part at a
 * time: inside a box it is held to, or in blocks (Reference#paint_scenery_in_blocks). While
 * +onto_sheet+ is set the background painters land there, as stored and with no blend, and every
 * row shows the map row +rows_tall+ rows above it at most, the top of its block. */
enum { NOTHING_ON_SHEET = -1 };
static int32_t sheet[CELLS];
static int32_t onto_sheet;
static int32_t rows_tall = 1;
static int64_t rows_split = -1; /* the row a split screen's blocks start again at, or -1 */

/* Scenery up, in the order it went up (Reference @bg_shown): one entry for every time a
 * background is put up, even one already up, exactly as the interpreter keeps it. The repeats
 * matter once layers are named. The order the stack asks for is worked out among the places the
 * entries hold in this list, so a background put up twice holds two of them, and leaving the
 * first out moves every background between the two. */
static int32_t *shown_backgrounds;
static int32_t shown_count, shown_room;

/* The four arrays below are what the game does to a background, and the interpreter keeps each by
 * the background's NAME. Two scenes can declare a background by one name, so each is read and
 * written at the entry that keeps it for the name (keeper_of, RG_BG_KEPT_BY), and the slots of
 * the other entries are never used.
 *
 * WHAT A BACKGROUND'S CELLS HOLD NOW (Reference @bg_maps): which map, of which entry's maps, and
 * the run's own copy of that map's cells, made the first time one of them is changed or another
 * map is handed over. The entry is the declaration that was up then (declaration_up), since two
 * scenes' declarations of one name can each have maps of their own. Until then each background
 * of the name shows its own first map, read where the game declared it. */
typedef struct { int32_t which, of; int16_t *cells; } background_cells;
static background_cells cells_now[RG_MAX_BACKGROUNDS];

/* Where a background's window sits over its map, in pixels (Reference @bg_scroll): the screen's
 * top left shows the map's (x, y). Nought until the game scrolls it. */
typedef struct { int32_t x, y; } background_scroll;
static background_scroll scrolls[RG_MAX_BACKGROUNDS];

/* The box a background is held to (Reference @bg_box), by the entry that keeps its name: whether
 * it is held to one, and its left, top, and the column and row just past it, kept to the screen
 * (Reference#screen_box). Held to none until the game sets one. */
typedef struct { int32_t held, left, top, right, bottom; } background_box;
static background_box boxes[RG_MAX_BACKGROUNDS];

/* The backgrounds put up this pass, shown from their top-left corner whatever their scroll
 * (Reference @bg_from_corner), whether there are any, and whether their pass has ended
 * (Reference @bg_corners_expired). */
static uint8_t from_corner[RG_MAX_BACKGROUNDS];
static int32_t any_from_corner, corners_expired;

/* The step of colors the game last named for a background's name, one more than it (Reference
 * @bg_colors): nought until the game names one. Which set of its tiles that draws each entry from
 * is worked out for the entry (tile_set_now), since two scenes' declarations of one name can have
 * different steps, or none. */
static int64_t colors_told[RG_MAX_BACKGROUNDS];

/* How a background is turned, once it has been turned or resized at all (Reference @bg_affine). */
typedef struct { int32_t turned, angle, size, pivot_x, pivot_y; } background_turn;
static background_turn turns[RG_MAX_BACKGROUNDS];

/* --- scenery --- */

/* The entry that keeps what the game does to this background's name (RG_BG_KEPT_BY): itself,
 * unless another scene declared a background by the same name after it. */
static int32_t keeper_of(int32_t background) { return background_field(background, RG_BG_KEPT_BY); }

/* Reference#background_up: the declaration of this background's name a line naming it means: the
 * one on the screen up now, where two scenes each declare one by the name, or the keeping entry
 * where none of them is up. */
static int32_t declaration_up(int32_t background) {
  int32_t keeper = keeper_of(background);
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (keeper_of(bg) == keeper && showing(bg)) return bg;
  return keeper;
}

/* Reference#background_swap: which set of its tiles this entry is drawn from now. 0 for the
 * colors they were drawn in, which is also what a number naming none of its steps means, or one
 * more than the step the game last named. */
static int32_t tile_set_now(int32_t background) {
  int64_t step = colors_told[keeper_of(background)] - 1;
  return step >= 0 && step < background_field(background, RG_BG_COLOR_STEPS) ? (int32_t)step + 1 : 0;
}

/* Reference#scroll_shown: where a background's window sits on the display now. */
static background_scroll scroll_shown(int32_t background) {
  int32_t keeper = keeper_of(background);
  return from_corner[keeper] ? (background_scroll){0, 0} : scrolls[keeper];
}

/* Reference#forget_expired_corners. The interpreter builds a picture that is rebuilt whole every
 * frame, so a background that stops being shown from its corner is drawn from its scroll on the
 * next one without anything asking. Here a frame that moved nothing builds nothing, so the
 * corners going is itself a change to the picture, and asks for it. */
static void forget_expired_corners(void) {
  if (!corners_expired) return;
  int32_t were_shown_from_corners = any_from_corner;
  corners_expired = 0;
  memset(from_corner, 0, sizeof from_corner);
  any_from_corner = 0;
  if (were_shown_from_corners && rebuilt_whole()) request_repaint();
}

/* Reference#mark_from_corner */
static void mark_from_corner(int32_t background) {
  forget_expired_corners();
  from_corner[keeper_of(background)] = 1;
  any_from_corner = 1;
}

/* Map number +which+ of a background's own maps, as its entry of rg_game_maps. */
static const int32_t *map_entry(int32_t background, int32_t which) {
  return rg_game_maps + RG_MAP_FIELDS * (background_field(background, RG_BG_FIRST_MAP) + which);
}

/* Reference#map_of: the map a background's cells hold now. That is the run's own copy for the
 * name where there is one, which is a copy of one of the maps of the entry it was made from; and
 * the first of this background's own maps where there is none. */
static const int32_t *map_now(int32_t background) {
  const background_cells *now = &cells_now[keeper_of(background)];
  return now->cells ? map_entry(now->of, now->which) : map_entry(background, 0);
}

static int32_t map_cols(int32_t background) { return map_now(background)[RG_MAP_COLS]; }
static int32_t map_rows(int32_t background) { return map_now(background)[RG_MAP_ROWS]; }

static int32_t in_map(int32_t background, int64_t row, int64_t col) {
  return row >= 0 && row < map_rows(background) && col >= 0 && col < map_cols(background);
}

/* Where a cell of the map is among its cells, which are kept row after row. */
static int64_t cell_place(int32_t background, int64_t row, int64_t col) { return row * map_cols(background) + col; }

/* Reference#map_of: what a cell holds NOW, in the run's own copy where there is one. Below nought
 * where it holds no tile. */
static int32_t map_cell(int32_t background, int64_t row, int64_t col) {
  if (!in_map(background, row, col)) return RG_CELL_EMPTY;
  const int16_t *own = cells_now[keeper_of(background)].cells;
  const int16_t *cells = own ? own : rg_game_map_cells + map_now(background)[RG_MAP_CELLS];
  return cells[cell_place(background, row, col)];
}

/* The name's cells become the run's own copy of map number +which+ of the maps of the declaration
 * up now, as that map was declared (Reference#mutable_map, and the copy in #exec_show_map). */
static void copy_map(int32_t background, int32_t which) {
  int32_t keeper = keeper_of(background), up = declaration_up(background);
  const int32_t *map = map_entry(up, which);
  size_t count = (size_t)map[RG_MAP_COLS] * (size_t)map[RG_MAP_ROWS];
  int16_t *copy = malloc((count ? count : 1) * sizeof *copy);
  if (!copy) rg_fault("no memory left for a background's own copy of its map");
  memcpy(copy, rg_game_map_cells + map[RG_MAP_CELLS], count * sizeof *copy);
  free(cells_now[keeper].cells);
  cells_now[keeper] = (background_cells){which, up, copy};
}

/* Each background with the name is drawn from its own first map again, as declared
 * (Reference's @bg_maps.delete). */
static void forget_own_cells(int32_t background) {
  free(cells_now[keeper_of(background)].cells);
  cells_now[keeper_of(background)] = (background_cells){0, 0, NULL};
}

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel), in the colors the
 * background is drawn with now (Reference#tile_colors): its tiles as drawn with each step come
 * one whole set after another. A tile the game paints is read from what it last copied in, and
 * shown in its run's colors as the background is drawn with them now. */
static uint16_t tile_pixel(int32_t background, int32_t cell, int64_t tx, int64_t ty) {
  int32_t painted = background_field(background, RG_BG_PAINTED);
  if (painted != RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] != RG_NOT_PAINTED) {
    int32_t run = rg_game_painted_tiles[painted + 2 * cell], which = rg_game_painted_tiles[painted + 2 * cell + 1];
    /* A big tile is kept as four squares, left to right and then down. */
    if (background_field(background, RG_BG_TILE_W) == 2 * RUN_TILE_SIDE) {
      which = which * 4 + (int32_t)(ty / RUN_TILE_SIDE) * 2 + (int32_t)(tx / RUN_TILE_SIDE);
      tx %= RUN_TILE_SIDE;
      ty %= RUN_TILE_SIDE;
    }
    int32_t place = places_of(run)[which * RUN_TILE_PIXELS + ty * RUN_TILE_SIDE + tx];
    int64_t set = (int64_t)tile_set_now(background) * rg_game_picture_sizes[RG_SIZE_RUNS] + run;
    return rg_game_run_colors[background_field(background, RG_BG_RUN_COLORS) + set * PLACES_IN_RUN_COLORS + place];
  }
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t tile = (int64_t)tile_set_now(background) * background_field(background, RG_BG_TILES) + cell;
  int64_t at = background_field(background, RG_BG_TILES_START) + tile * tile_w * tile_h + ty * tile_w + tx;
  return tile_pixels_drawn[at];
}

/* Reference#grid_repeats: how many times the grid is seen along one side of the screen. A grid of
 * 8-by-8 tiles comes round, so where the screen is wider or taller than the grid (a Genesis's 320
 * across is wider than 32 cells of 8 pixels) the map is seen again past the grid's edge. */
static int32_t grid_repeats(int32_t background, int32_t grid_cells, int32_t screen_side) {
  if (background_field(background, RG_BG_NEVER_WRAPS) || background_field(background, RG_BG_TILE_W) != 8 ||
      background_field(background, RG_BG_TILE_H) != 8)
    return 1;
  int32_t grid_side = grid_cells * 8;
  return (screen_side + grid_side - 1) / grid_side;
}

/* The map onto the picture with its corner at (left, top), cell by cell. */
static void stamp_map_at(int32_t background, int64_t left, int64_t top) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  for (int32_t row = 0; row < map_rows(background); row++) {
    for (int32_t col = 0; col < map_cols(background); col++) {
      int32_t cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (int32_t ty = 0; ty < tile_h; ty++)
        for (int32_t tx = 0; tx < tile_w; tx++) {
          uint16_t color = tile_pixel(background, cell, tx, ty);
          if (color != RG_SEE_THROUGH) set_pixel(left + (int64_t)col * tile_w + tx, top + (int64_t)row * tile_h + ty, color);
        }
    }
  }
}

/* Reference#stamp_background: the whole map onto the picture, as many times as the screen sees it. */
void rg_background_stamp(int32_t background) {
  /* Reference#stamp_background: a status bar is painted from its own top as the view is built, and
   * a background held above a row stops at it. */
  if (background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR || boxes[keeper_of(background)].held) {
    request_repaint();
    return;
  }
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  int32_t grid_cols = map_now(background)[RG_MAP_GRID_COLS], grid_rows = map_now(background)[RG_MAP_GRID_ROWS];
  int32_t across = grid_repeats(background, grid_cols, RG_SCREEN_WIDTH);
  int32_t down = grid_repeats(background, grid_rows, RG_SCREEN_HEIGHT);
  for (int32_t round_down = 0; round_down < down; round_down++)
    for (int32_t round_across = 0; round_across < across; round_across++)
      stamp_map_at(background, (int64_t)round_across * grid_cols * 8, (int64_t)round_down * grid_rows * 8);
  mix_nothing();
}

static int32_t stack_place(int32_t background) { return background_field(background, RG_BG_STACK_PLACE); }

/* Reference#behind?: only when both named a layer. */
static int32_t behind(int32_t a, int32_t b) {
  return stack_place(a) != RG_NO_LAYER && stack_place(b) != RG_NO_LAYER && stack_place(a) < stack_place(b);
}

/* One more entry on the list of scenery up. */
static void remember_put_up(int32_t background) {
  if (shown_count == shown_room) {
    if (shown_room >= (1 << 28)) rg_fault("scenery has been put up too many times to remember");
    shown_room = shown_room ? shown_room * 2 : RG_MAX_BACKGROUNDS;
    shown_backgrounds = realloc(shown_backgrounds, (size_t)shown_room * sizeof *shown_backgrounds);
    if (!shown_backgrounds) rg_fault("no memory left to remember the scenery that is up");
  }
  shown_backgrounds[shown_count++] = background;
}

/* Whether an entry of the list is among those being put in order: every one, or (+over+ a
 * background) only the ones a named layer puts in front of it. */
static int32_t in_order_asked(int32_t entry, int32_t over) { return over < 0 || behind(over, entry); }

/* Where the LAST entry for +background+ lands once the entries asked for are put in the order the
 * stack asks for (IR::Stacking.order_by_stack), counting from 0 among them, or -1 when it has no
 * entry. An entry that named no layer stays where it is. The ones that did are sorted by how far
 * forward their layers are — two in one layer keeping the order they came in — and handed, in that
 * order, the places the named entries held. */
static int64_t last_place_in_stack_order(int32_t background, int32_t over) {
  int32_t place = stack_place(background);
  int64_t at = -1, last = -1, further_back = 0, in_its_layer = 0, in_its_layer_by_last = 0;
  for (int32_t i = 0; i < shown_count; i++) {
    int32_t entry = shown_backgrounds[i];
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) != RG_NO_LAYER && stack_place(entry) < place) further_back++;
    if (stack_place(entry) != RG_NO_LAYER && stack_place(entry) == place) in_its_layer++;
    if (entry == background) {
      last = at;
      in_its_layer_by_last = in_its_layer;
    }
  }
  if (last < 0 || place == RG_NO_LAYER) return last;

  /* It is the named entry number +nth+ in sorted order, so it takes the place of the named entry
   * number +nth+ in the order they went up. */
  int64_t nth = further_back + in_its_layer_by_last - 1, named = -1;
  at = -1;
  for (int32_t i = 0; i < shown_count; i++) {
    int32_t entry = shown_backgrounds[i];
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) != RG_NO_LAYER && ++named == nth) return at;
  }
  return -1;
}

/* Reference#in_stack_order over the scenery that is up — all of it, or the part a named layer
 * puts in front of +over+ — with each one stamped in that order.
 *
 * The list can hold a background many times, and stamping one again paints over every stamp of
 * it before. So only where the last entry for each background lands decides the picture, and
 * each is stamped once, in the order of those places. */
static void stamp_in_stack_order(int32_t over) {
  if (over >= 0 && stack_place(over) == RG_NO_LAYER) return;
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  int64_t lands[RG_MAX_BACKGROUNDS];
  for (int32_t bg = 0; bg < backgrounds; bg++) lands[bg] = last_place_in_stack_order(bg, over);
  for (;;) {
    int32_t next = -1;
    for (int32_t bg = 0; bg < backgrounds; bg++)
      if (lands[bg] >= 0 && (next < 0 || lands[bg] < lands[next])) next = bg;
    if (next < 0) return;
    rg_background_stamp(next);
    lands[next] = -1;
  }
}

/* The start of Reference#take_over (see rg_screen.h). */
void rg_background_forget_cells(int32_t background) { forget_own_cells(background); }

/* The cell changes of backgrounds declared `held: true`, waiting for rg_show_held_tiles
 * (Reference's @held_tiles), in the order the game made them. */
typedef struct {
  int32_t background, col, row, tile;
} held_tile;
static held_tile held_tiles[RG_HELD_TILES_ROOM];
static int32_t held_tile_count = 0;

/* Reference#put_up_background: a change still waiting to +background+'s name was made to cells put
 * up again now. The changes to every other background are kept, in the order made. */
static void forget_held_tiles(int32_t background) {
  int32_t keeper = keeper_of(background), kept = 0;
  for (int32_t i = 0; i < held_tile_count; i++)
    if (keeper_of(held_tiles[i].background) != keeper) held_tiles[kept++] = held_tiles[i];
  held_tile_count = kept;
}

/* Reference#put_up_background. A stamp only covers where it has solid pixels, so a background a
 * named layer puts BEHIND one already up would land in front of it; the ones it belongs behind
 * are stamped again over it. A turned background is painted through its turn at the next rebuild,
 * and a status bar from its own top,
 * rather than stamped as drawn. So is anything put up while a placed fade is in the picture, which
 * a stamp leaves out. */
void rg_background_put_up(int32_t background) {
  forget_held_tiles(background);
  if (background_field(background, RG_BG_ON_ARRIVAL)) {
    forget_own_cells(background);
    boxes[keeper_of(background)].held = 0; /* its scene puts it up showing everywhere */
  }
  remember_put_up(background);
  mark_from_corner(background);
  scenery_kept = 0;
  if (turns[keeper_of(background)].turned || background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR || bar_showing() >= 0 ||
      boxes[keeper_of(background)].held || placed_fade_in_picture()) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
  stamp_in_stack_order(background);
}

/* Reference#exec_affine_background: the angle wraps into 0..359 as Ruby's % does. */
void rg_background_turn(int32_t background, int32_t angle, int32_t size, int32_t pivot_x, int32_t pivot_y) {
  turns[keeper_of(background)] = (background_turn){1, (int32_t)floor_mod(angle, 360), size, pivot_x, pivot_y};
  request_repaint();
}

/* Reference#showing_scenery: scenery every screen shows, and the running scene's own. */
static int32_t showing(int32_t background) {
  int32_t scene = background_field(background, RG_BG_SCENE);
  return scene == RG_EVERY_SCENE || scene == current_scene;
}

/* Reference#exec_scroll_background. The interpreter builds the view again every time; this builds
 * it again only when the scroll the picture shows is not the one it was built with, so a frame
 * that sets the same scroll again costs nothing. What the picture shows is what scroll_shown
 * answers, which for a background put up this pass is its corner, so a scroll set over a corner
 * is a change even where the number written is the one already stored. */
void rg_background_scroll(int32_t background, int32_t x, int32_t y) {
  background_scroll before = scroll_shown(background);
  scrolls[keeper_of(background)] = (background_scroll){x, y};
  if (!placing_at_pass_end) from_corner[keeper_of(background)] = 0;
  background_scroll after = scroll_shown(background);
  if (after.x != before.x || after.y != before.y) request_repaint();
  else skip_repaint();
}

/* Where each status bar was last placed, by the entry that keeps its name, and whether it has
 * been (Reference @bar_top). */
static int32_t bar_tops[RG_MAX_BACKGROUNDS];
static uint8_t bar_placed[RG_MAX_BACKGROUNDS];

/* Reference#exec_place_bar */
void rg_place_bar(int32_t background, int32_t top) {
  bar_tops[keeper_of(background)] = clamp32(top, 0, RG_SCREEN_HEIGHT);
  bar_placed[keeper_of(background)] = 1;
  if (!placing_at_pass_end) from_corner[keeper_of(background)] = 0;
  request_repaint();
}

/* Reference#exec_box_background and #screen_box: a box with nothing on the screen is an empty one
 * at the corner. */
void rg_background_box(int32_t background, int32_t x, int32_t y, int32_t width, int32_t height, int32_t held) {
  background_box *box = &boxes[keeper_of(background)];
  if (held == 0) {
    box->held = 0;
  } else {
    *box = (background_box){1, 0, 0, 0, 0};
    if (width > 0 && height > 0) {
      int32_t left = clamp32(x, 0, RG_SCREEN_WIDTH), right = clamp32((int64_t)x + width, 0, RG_SCREEN_WIDTH);
      int32_t top = clamp32(y, 0, RG_SCREEN_HEIGHT), bottom = clamp32((int64_t)y + height, 0, RG_SCREEN_HEIGHT);
      if (right > left && bottom > top) *box = (background_box){1, left, top, right, bottom};
    }
  }
  request_repaint();
}

/* Which status bars hide the sprites from their top down, by the same entry (Reference @bar_covers). */
static uint8_t bar_covers[RG_MAX_BACKGROUNDS];

void rg_bar_covers(int32_t background, int32_t covers) {
  bar_covers[keeper_of(background)] = covers != 0;
  request_repaint();
}

/* Reference#bar_top_shown */
static int32_t bar_top_shown(int32_t bar) {
  int32_t declared = clamp32(background_field(bar, RG_BG_BAR_TOP), 0, RG_SCREEN_HEIGHT);
  int32_t keeper = keeper_of(bar);
  return from_corner[keeper] || !bar_placed[keeper] ? declared : bar_tops[keeper];
}

/* Reference#bar_showing: the status bar on screen, or -1. */
static int32_t bar_showing(void) {
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg) && background_field(bg, RG_BG_BAR_TOP) != RG_NOT_A_BAR) return bg;
  return -1;
}

/* Reference#scenery_rows */
static int64_t scenery_rows(void) {
  int32_t bar = bar_showing();
  return bar < 0 ? RG_SCREEN_HEIGHT : bar_top_shown(bar);
}

/* Reference#rows_shown_of */
static int64_t rows_shown_of(int32_t background) {
  int32_t above = background_field(background, RG_BG_ABOVE_ROW);
  int64_t rows = scenery_rows();
  return above != RG_NOT_A_BAR && above < rows ? above : rows;
}

/* Reference#block_split: the row the screen is split at, where its blocks start again (the top of
 * the status bar showing, or the row a background showing is held above), or -1. */
static int64_t block_split(void) {
  int32_t bar = bar_showing();
  if (bar >= 0) return bar_top_shown(bar);
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg) && background_field(bg, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR) return background_field(bg, RG_BG_ABOVE_ROW);
  return -1;
}

/* Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. */
void rg_background_set_tile(int32_t background, int32_t col, int32_t row, int32_t tile) {
  /* A tile only another scene's declaration of the name has changes nothing here. */
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (!cells_now[keeper_of(background)].cells) copy_map(background, 0);
  if (!in_map(background, row, col)) return;
  int16_t *cell = &cells_now[keeper_of(background)].cells[cell_place(background, row, col)];
  if (*cell == tile) return;
  *cell = (int16_t)tile;
  request_repaint();
}

/* Reference#exec_set_tile, for a background declared `held: true`: the change waits, its cell
 * worked out now, for rg_show_held_tiles. With +most+ waiting, everything waiting goes in first. */
void rg_background_hold_tile(int32_t background, int32_t col, int32_t row, int32_t tile, int32_t most) {
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (held_tile_count >= most || held_tile_count >= RG_HELD_TILES_ROOM) rg_show_held_tiles();
  held_tiles[held_tile_count++] = (held_tile){background, col, row, tile};
}

/* Reference#exec_show_held_tiles: every change waiting, in the order the game made them. */
void rg_show_held_tiles(void) {
  int32_t waiting = held_tile_count;
  held_tile_count = 0;
  for (int32_t i = 0; i < waiting; i++) {
    held_tile change = held_tiles[i];
    rg_background_set_tile(change.background, change.col, change.row, change.tile);
  }
}

/* Reference#exec_show_map: of the maps of the declaration up now. */
void rg_background_show_map(int32_t background, int32_t which) {
  if (which < 0 || which >= background_field(declaration_up(background), RG_BG_SHOWABLE_MAPS)) return;
  copy_map(background, which);
  request_repaint();
}

/* Reference#exec_background_colors: nothing about the map or the pictures changes, and the next
 * rebuild reads the tiles in the colors named. The number is kept for the name, as the interpreter
 * keeps it, and what it names is worked out for each entry as it is drawn (tile_set_now). A
 * number below nought names no step, and is kept as nought, the same as none named. */
void rg_background_draw_with(int32_t background, int32_t which) {
  colors_told[keeper_of(background)] = which < 0 ? 0 : (int64_t)which + 1;
  request_repaint();
}

/* Reference#followed_background_swap, a list at a time. A background that follows several lists
 * the game changes is drawn from its tiles as declared, and its tiles as each list's sets draw
 * them come after those, a whole set of tiles each. So when a list is told what to hold, the tiles
 * drawn from that list are copied from set number +set+ over the ones the picture is drawn from,
 * and the other lists' tiles stay as they are. A tile that holds those colors already is left, and
 * the picture is asked for only when one changed. The game asks again as a state is read or
 * written (its visit_state): a state holds the number each list holds and not these copies, so a
 * run read from one copies them then, and a run writing one finds them made and copies nothing. */
void rg_background_follow(const int32_t *rules, int32_t set) {
  int32_t background = rules[1], count = rules[2], changed = 0;
  size_t tile_size = (size_t)background_field(background, RG_BG_TILE_W) * (size_t)background_field(background, RG_BG_TILE_H);
  size_t start = (size_t)background_field(background, RG_BG_TILES_START);
  size_t set_size = (size_t)background_field(background, RG_BG_TILES) * tile_size;
  for (int32_t i = 0; i < count; i++) {
    size_t to = start + (size_t)rules[3 + i] * tile_size, from = to + (size_t)set * set_size;
    if (!memcmp(tile_pixels_drawn + to, tile_pixels_drawn + from, tile_size * sizeof *tile_pixels_drawn)) continue;
    uint16_t *pixels = rg_screen_tile_pixels_to_fill(rules[0]);
    memcpy(pixels + to, pixels + from, tile_size * sizeof *pixels);
    changed = 1;
  }
  if (changed) request_repaint();
}

/* Framebuffer#paint_row, a cell at a time: one color of scenery laid on the picture at (px, py),
 * which is on the screen, mixed and faded as whatever is in force sets. */
static void lay_scenery(int64_t px, int64_t py, uint16_t color) {
  uint16_t *into = &pixels[py * RG_SCREEN_WIDTH + px];
  *into = into_cell(color, *into, pixels, py * RG_SCREEN_WIDTH + px);
  if (sprites_seen_through()) picture_without_sprites[py * RG_SCREEN_WIDTH + px] = *into;
}

/* ONE ROW OF THE SCREEN FROM ONE ROW OF A BACKGROUND'S MAP: the screen's pixel px shows map column
 * off_x + px, taken round at +wrap_w+ where the map wraps, or not at all (0) where it does not.
 * +my+ is not below nought. Where the map has no cell or no tile, or the tile is see-through,
 * what is behind stays.
 *
 * A tile is the same for every pixel of its row, so the cell is looked up once for each tile the
 * row crosses, not once for each pixel, and the pixels are read from the tile's row in turn. Where
 * the map wraps it wraps at a whole number of tiles, so a tile is never cut by the wrap. A painted
 * tile (one whose pixels the game paints while it runs) is read the slow way, since where its
 * pixels are depends on the cell.
 *
 * With no fade painted in and no see-through layer being mixed, lay_scenery comes to storing the
 * colour, marking the cell as no mix, and keeping it in the picture without sprites where that is
 * kept; so that is done here, and anything else goes through lay_scenery. */
static void paint_map_row(int32_t background, int64_t my, int64_t off_x, int64_t wrap_w, int64_t py) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const int32_t *map = map_now(background);
  int32_t cols = map[RG_MAP_COLS];
  int64_t row = my / tile_h;
  if (row >= map[RG_MAP_ROWS]) return;
  const int16_t *own = cells_now[keeper_of(background)].cells;
  const int16_t *row_cells = (own ? own : rg_game_map_cells + map[RG_MAP_CELLS]) + row * cols;
  int64_t ty = my % tile_h;
  int32_t painted = background_field(background, RG_BG_PAINTED);
  int64_t set_start = background_field(background, RG_BG_TILES_START) +
                      (int64_t)tile_set_now(background) * background_field(background, RG_BG_TILES) * tile_w * tile_h +
                      ty * tile_w;
  int32_t plain = !paint_fade && !mixing;
  int32_t keeps_picture_without_sprites = sprites_seen_through();
  for (int64_t px = 0; px < RG_SCREEN_WIDTH;) {
    int64_t mx = off_x + px;
    if (wrap_w) mx %= wrap_w;
    if (mx < 0) { /* only where the map does not wrap: nothing until the map's left edge */
      px -= mx;
      continue;
    }
    int64_t col = mx / tile_w, tx = mx - col * tile_w, run = tile_w - tx;
    if (run > RG_SCREEN_WIDTH - px) run = RG_SCREEN_WIDTH - px;
    int32_t cell = col < cols ? row_cells[col] : RG_CELL_EMPTY;
    if (cell >= 0) {
      int32_t slow = painted != RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] != RG_NOT_PAINTED;
      int64_t from = set_start + (int64_t)cell * tile_w * tile_h + tx;
      for (int64_t i = 0; i < run; i++) {
        uint16_t color = slow ? tile_pixel(background, cell, tx + i, ty) : tile_pixels_drawn[from + i];
        if (color == RG_SEE_THROUGH) continue;
        int64_t at = py * RG_SCREEN_WIDTH + px + i;
        if (onto_sheet) {
          sheet[at] = color;
        } else if (plain) {
          pixels[at] = color;
          picture_mixes.is_mixed[at] = 0;
          if (keeps_picture_without_sprites) picture_without_sprites[at] = color;
        } else {
          lay_scenery(px + i, py, color);
        }
      }
    }
    px += run;
  }
}

/* The row of the picture that screen row +py+ is drawn from: its own, or the row at the top of
 * its block while a background is being painted for blocks (Blocks.block_top), the blocks below
 * +rows_split+ counted from it. */
static int64_t row_drawn_from(int64_t py) {
  if (rows_split >= 0 && py >= rows_split) return rows_split + (py - rows_split) / rows_tall * rows_tall;
  return py - py % rows_tall;
}

/* The background and the line of the screen the game is being asked about, when it is being
 * asked, and how far across it answered. */
static struct { int32_t background, py, offset; } asked_bend = {NOBODY_ASKED, 0, 0};

int32_t rg_bend_asked(int32_t background) { return background == asked_bend.background; }
int32_t rg_bend_line(void) { return asked_bend.py; }
void rg_bend_answer(int32_t offset) { asked_bend.offset = offset; }

/* Every line of every bent background, as the gap between frames last worked it out
 * (Reference#work_out_bends), by the background that keeps the name, and whether it has been. */
static int32_t bend_lines[RG_MAX_BACKGROUNDS][RG_SCREEN_HEIGHT];
static int32_t bend_lines_kept[RG_MAX_BACKGROUNDS];

/* Reference#run_bend_for_row: the game asked how far across line +py+ of the background that
 * keeps the name sits, after running whatever is in its block. */
static int32_t run_bend_for_line(int32_t keeper, int32_t py) {
  asked_bend.background = keeper;
  asked_bend.py = py;
  rg_game_bend_offsets();
  asked_bend.background = NOBODY_ASKED;
  return asked_bend.offset;
}

/* Lines +first_line+ up to +past_line+ of one background, worked out in turn and kept. */
void rg_bend_work_out(int32_t background, int32_t first_line, int32_t past_line) {
  int32_t keeper = keeper_of(background); /* the game answers for the name */
  for (int32_t py = first_line; py < past_line; py++) bend_lines[keeper][py] = run_bend_for_line(keeper, py);
  bend_lines_kept[keeper] = 1;
}

/* Reference#work_out_bends, last in every frame boundary of a game that bends a background it
 * has: every bend's lines are worked out, and the picture is owed again, since the lines are
 * worked out from whatever the blocks read. */
void rg_screen_work_out_bends(void) {
  rg_game_work_out_bends();
  if (frames_begun) request_repaint();
}

/* Reference#bend_offset_at: how far across line +py+ of the screen a background sits, on top of
 * its scroll, as the gap between frames last worked it out. Before the first gap: flat for a game
 * that waits for the screen, whose table on the console is nought until then, and worked out as
 * the line is painted for one that never waits, as the console works each line out as it draws.
 * Nought for a background the game does not bend. */
static int64_t bend_at(int32_t background, int64_t py) {
  if (!background_field(background, RG_BG_BENT)) return 0;
  int32_t keeper = keeper_of(background);
  if (bend_lines_kept[keeper]) return bend_lines[keeper][py];
  return frames_begun ? 0 : run_bend_for_line(keeper, (int32_t)py);
}

/* Reference#paint_streamed_background_window: a background with a map too big for any grid, or
 * with maps of different sizes, does not come round again. Past any edge of the map it is
 * showing there are no cells: left of it, above it and below it by the tests here, right of it
 * because the map has no such cell to read. A bent one in a game that never waits for the screen,
 * whose lines are worked out as they are painted, is asked only about the rows its map reaches. */
static void paint_window_without_wrapping(int32_t background) {
  int64_t map_h = (int64_t)map_rows(background) * background_field(background, RG_BG_TILE_H);
  background_scroll scroll = scroll_shown(background);
  for (int64_t py = 0, rows = rows_shown_of(background); py < rows; py++) {
    int64_t my = (int64_t)scroll.y + row_drawn_from(py);
    if (my < 0 || my >= map_h) continue;
    int64_t off_x = (int64_t)scroll.x + bend_at(background, py);
    paint_map_row(background, my, off_x, 0, py);
  }
}

/* Reference#paint_background_window, for a background never turned: the window sits where the
 * background is scrolled to, the map wraps over the console's whole grid, and a row or cell past
 * the map shows what is behind. */
static void paint_window(int32_t background) {
  if (background_field(background, RG_BG_NEVER_WRAPS)) {
    paint_window_without_wrapping(background);
    return;
  }
  int64_t map_w = (int64_t)map_now(background)[RG_MAP_GRID_COLS] * background_field(background, RG_BG_TILE_W);
  int64_t map_h = (int64_t)map_now(background)[RG_MAP_GRID_ROWS] * background_field(background, RG_BG_TILE_H);
  if (map_w == 0 || map_h == 0) return;
  background_scroll scroll = scroll_shown(background);
  int64_t off_y = floor_mod(scroll.y, map_h);
  for (int64_t py = 0, rows = rows_shown_of(background); py < rows; py++) {
    int64_t off_x = floor_mod((int64_t)scroll.x + bend_at(background, py), map_w);
    paint_map_row(background, (off_y + row_drawn_from(py)) % map_h, off_x, map_w, py);
  }
}

/* Reference#paint_affine_background_window: for each screen pixel, work back through the turn
 * to the map pixel that lands there, from wherever the background is scrolled to. */
static void paint_turned_window(int32_t background) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t map_w = (int64_t)map_now(background)[RG_MAP_GRID_COLS] * tile_w;
  int64_t map_h = (int64_t)map_now(background)[RG_MAP_GRID_ROWS] * tile_h;
  if (map_w == 0 || map_h == 0) return;
  const background_turn *turn = &turns[keeper_of(background)];
  int64_t pivot_x = turn->pivot_x, pivot_y = turn->pivot_y, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix(turn->angle, turn->size, &turn_cos, &turn_sin);
  /* A turned layer is placed by its turn, which putting it up leaves as it is. */
  background_scroll scroll = scrolls[keeper_of(background)];
  for (int64_t py = 0, rows = scenery_rows(); py < rows; py++) {
    int64_t dy = row_drawn_from(py) - pivot_y;
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      int64_t dx = px - pivot_x;
      int64_t mx = floor_mod(scroll.x + pivot_x + floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      int64_t my = floor_mod(scroll.y + pivot_y + floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
      int32_t cell = map_cell(background, my / tile_h, mx / tile_w);
      if (cell < 0) continue;
      uint16_t color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color == RG_SEE_THROUGH) continue;
      if (onto_sheet) sheet[py * RG_SCREEN_WIDTH + px] = color;
      else set_pixel(px, py, color);
    }
  }
}

/* Reference#paint_background_window: one background painted where it sits in the view. */
static void paint_background(int32_t background) {
  if (turns[keeper_of(background)].turned) paint_turned_window(background);
  else paint_window(background);
}

/* Reference#paint_status_bar_rows: from its top row to the bottom of the screen, its map from its own
 * corner, never scrolled; past the end of its map the backdrop stays. */
static void paint_status_bar_rows(int32_t bar) {
  int64_t top = bar_top_shown(bar);
  for (int64_t py = top; py < RG_SCREEN_HEIGHT; py++) paint_map_row(bar, row_drawn_from(py) - top, 0, 0, py);
}

/* Reference#paint_status_bar: the status bar as drawn, or in blocks while the picture is shown in them and
 * the game puts its bar there too (RG_BG_IN_BLOCKS), its blocks starting at its own top row. */
static void paint_status_bar(int32_t bar) {
  int32_t block = rg_hook_block_size();
  if (block == 1 || !background_field(bar, RG_BG_IN_BLOCKS)) {
    paint_status_bar_rows(bar);
    return;
  }
  for (int32_t i = 0; i < CELLS; i++) sheet[i] = NOTHING_ON_SHEET;
  onto_sheet = 1;
  rows_tall = block;
  rows_split = bar_top_shown(bar);
  paint_status_bar_rows(bar);
  onto_sheet = 0;
  rows_tall = 1;
  rows_split = -1;
  for (int64_t py = bar_top_shown(bar); py < RG_SCREEN_HEIGHT; py++)
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      int32_t color = sheet[py * RG_SCREEN_WIDTH + px - px % block];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, (uint16_t)color);
    }
}

/* Reference#paint_scenery_in_blocks: ONE BACKGROUND IN BLOCKS of +block+ pixels each way, by the
 * display's own rule, while the picture is shown in them (rg_hook_block_size).
 *
 * The blocks are fixed to the screen, and each shows the color the background has at the block's
 * top left corner, so a background that scrolls slides under a grid that stays where it is. A
 * corner that is see-through leaves the whole block see-through.
 *
 * Down and across are done apart, because a display draws a row at a time. Down: every row of a
 * block is drawn from the map row its top row shows, and still placed by its OWN bend, so a
 * background bent row by row keeps each row's bend and a block of it is a sheared one. Across:
 * each pixel of a row then takes the one at the start of its block in that same row. So the
 * background goes onto the sheet rows first, and is laid on the picture through the blocks, with
 * whatever mix or fade is in force for it applied as it is laid. A background held to a box keeps
 * to the box as it is laid (+box+, or NULL).
 *
 * Reference#block_width_across: a background that can turn is left one pixel wide at a size of
 * two, so its rows double and its columns do not. That is the emulator's, kept because the
 * console's picture is checked against it. */
static void paint_scenery_in_blocks(int32_t background, int32_t block, const background_box *box) {
  for (int32_t i = 0; i < CELLS; i++) sheet[i] = NOTHING_ON_SHEET;
  onto_sheet = 1;
  rows_tall = block;
  rows_split = block_split();
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  rows_split = -1;
  int32_t wide = background_field(background, RG_BG_CAN_TURN) && block == 2 ? 1 : block;
  for (int64_t py = 0, rows = scenery_rows(); py < rows; py++)
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      if (box && (px < box->left || px >= box->right || py < box->top || py >= box->bottom)) continue;
      int32_t color = sheet[py * RG_SCREEN_WIDTH + px - px % wide];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, (uint16_t)color);
    }
}

/* Reference#paint_scenery_in_box: a background held to a box goes onto the sheet as it would onto
 * the picture, and only its pixels inside the box are laid on the picture. */
static void paint_scenery_in_box(int32_t background, const background_box *box) {
  for (int32_t i = 0; i < CELLS; i++) sheet[i] = NOTHING_ON_SHEET;
  onto_sheet = 1;
  paint_background(background);
  onto_sheet = 0;
  for (int64_t py = box->top; py < box->bottom; py++)
    for (int64_t px = box->left; px < box->right; px++) {
      int32_t color = sheet[py * RG_SCREEN_WIDTH + px];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, (uint16_t)color);
    }
}

/* Reference#paint_scenery: a background held to a box with nothing in it paints nothing; one the
 * game has not left as drawn is painted in blocks while the blocks are bigger than a pixel. */
static void paint_scenery(int32_t background) {
  const background_box *box = boxes[keeper_of(background)].held ? &boxes[keeper_of(background)] : NULL;
  if (box && (box->right <= box->left || box->bottom <= box->top)) return;
  int32_t block = rg_hook_block_size();
  if (block > 1 && background_field(background, RG_BG_IN_BLOCKS)) paint_scenery_in_blocks(background, block, box);
  else if (box) paint_scenery_in_box(background, box);
  else paint_background(background);
}

/* Reference#set_blend_for, for scenery: what is painted next is mixed as the layer the background
 * is in, and faded unless a placed fade leaves it as drawn. */
static void blend_as_background(int32_t background) {
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  fade_unless_left_as_drawn(background_field(background, RG_BG_FADE_PLACE));
}

/* --- the hooks it takes --- */

/* Reference#exec_screen: a screen of another kind wipes the scenery, and arriving on one drawn
 * from tiles puts up again what every such screen shows, as declared (#put_up_always_up). */
static void rg_tiled_screen_crossed(int32_t new_kind) {
  shown_count = 0;
  if (new_kind == RG_BITMAP) return;
  for (int32_t i = 0; i < rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]; i++) {
    forget_own_cells(rg_game_always_up[i]);
    rg_background_put_up(rg_game_always_up[i]);
  }
}

/* The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its
 * picture is painted (Reference#forget_expired_corners). */
static void rg_tiled_frame_ended(void) {
  if (any_from_corner) corners_expired = 1;
}

static void rg_tiled_repaint_requested(void) { forget_expired_corners(); }
static void rg_tiled_rebuild_checked(void) { forget_expired_corners(); }

/* The status bar's state while the view is rebuilt, from rg_tiled_repaint_began to
 * rg_tiled_repaint_ending: the bar on screen, or -1. */
static int32_t bar_in_rebuild = -1;

/* A status bar is painted first: no background is painted under it, so it is in front of all of
 * them and every sprite is painted over it. */
static void rg_tiled_repaint_began(void) {
  bar_in_rebuild = bar_showing();
  if (bar_in_rebuild < 0) return;
  blend_as_background(bar_in_rebuild);
  paint_status_bar(bar_in_rebuild);
}

static void rg_tiled_paint_level(int32_t level) {
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (!showing(bg) || background_field(bg, RG_BG_LEVEL) != level) continue;
    blend_as_background(bg);
    paint_scenery(bg);
  }
}

/* Reference#paint_bar_over_sprites */
static void rg_tiled_repaint_ending(void) {
  int32_t bar = bar_in_rebuild;
  bar_in_rebuild = -1;
  if (bar < 0 || !bar_covers[keeper_of(bar)]) return;
  int32_t top = bar_top_shown(bar);
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  fill_cells(0, top, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT - top, backdrop);
  blend_as_background(bar);
  paint_status_bar(bar);
}

/* Reference#scene_framebuffer: every background showing, stamped. */
static void rg_tiled_stamp_scenery(void) {
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg)) rg_background_stamp(bg);
}

static int32_t rg_tiled_scenery_up(void) { return shown_count > 0; }

/* Reference#layer_has_anything?, for scenery: a background showing now in that layer. */
static int32_t rg_tiled_layer_holds_scenery(int32_t layer) {
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg) && background_field(bg, RG_BG_SEE_THROUGH) == layer) return 1;
  return 0;
}

/* Reference#take_down_scenery: the last scene's own scenery comes down, and the picture goes back
 * to the scenery every screen shows. A placed fade stays across the change, so while one is in the
 * picture the view is rebuilt with it. Answers whether any came down. */
static int32_t rg_tiled_scene_take_down(int32_t brings_scenery) {
  int32_t any_scene_owned = 0;
  for (int32_t i = 0; i < shown_count; i++)
    if (background_field(shown_backgrounds[i], RG_BG_SCENE) != RG_EVERY_SCENE) any_scene_owned = 1;
  if (!any_scene_owned && !brings_scenery) return 0;

  rg_screen_paint_owed_rebuild();
  int32_t kept = 0;
  for (int32_t i = 0; i < shown_count; i++)
    if (!background_field(shown_backgrounds[i], RG_BG_ON_ARRIVAL)) shown_backgrounds[kept++] = shown_backgrounds[i];
  if (kept == shown_count) return 0;

  shown_count = kept;
  scenery_kept = 0;
  clear_to(backdrop);
  stamp_in_stack_order(-1);
  if (placed_fade_in_picture()) request_repaint();
  return 1;
}

/* --- the state image --- */

/* What each background's name keeps, in "tiled.backgrounds": whether it has cells of its own, which
 * map and whose they copy, its scroll, whether it is shown from its corner, the colors last named,
 * its box (held, then left, top, right, bottom, all nought where it is held to none), its turn
 * (turned, angle, size, pivot), where its status bar was placed and whether, whether the bar covers
 * the sprites, and whether its bends were worked out. */
enum {
  STATE_HAS_OWN_CELLS = 0, STATE_MAP_WHICH = 1, STATE_MAP_OF = 2, STATE_BENDS_KEPT = 20,
  BACKGROUND_STATE_NUMBERS = 21,
};
enum { HELD_TILE_NUMBERS = 4 };            /* background, column, row, tile */
enum { MOST_SCENERY_PUT_UP = 1 << 28 };    /* remember_put_up's limit */

/* How many cells a copy of map +which+ of entry +of+ holds. */
static int64_t map_copy_cell_count(int32_t of, int32_t which) {
  const int32_t *map = map_entry(of, which);
  return (int64_t)map[RG_MAP_COLS] * map[RG_MAP_ROWS];
}

/* How many cells a background's own copy holds, by its numbers in "tiled.backgrounds": none where
 * it has no copy. */
static int64_t own_copy_cell_count(const int64_t *numbers) {
  if (!numbers[STATE_HAS_OWN_CELLS]) return 0;
  return map_copy_cell_count((int32_t)numbers[STATE_MAP_OF], (int32_t)numbers[STATE_MAP_WHICH]);
}

/* Each background's numbers, as "tiled.backgrounds" holds them, for +numbers+ to be written. */
static void background_state_numbers(int32_t background, int64_t *numbers) {
  const background_cells *cells = &cells_now[background];
  const background_box *box = &boxes[background];
  const background_turn *turn = &turns[background];
  int64_t held = box->held;
  int64_t kept[BACKGROUND_STATE_NUMBERS] = {
    cells->cells != NULL, cells->which, cells->of, scrolls[background].x, scrolls[background].y,
    from_corner[background], colors_told[background],
    held, held ? box->left : 0, held ? box->top : 0, held ? box->right : 0, held ? box->bottom : 0,
    turn->turned, turn->angle, turn->size, turn->pivot_x, turn->pivot_y,
    bar_tops[background], bar_placed[background], bar_covers[background], bend_lines_kept[background],
  };
  memcpy(numbers, kept, sizeof kept);
}

/* A background's numbers read from the image, all but its cells. */
static void read_background_state(int32_t background, const int64_t *n) {
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  int64_t which = n[STATE_MAP_WHICH], of = n[STATE_MAP_OF];
  if (n[STATE_HAS_OWN_CELLS] && (of < 0 || of >= backgrounds || which < 0 ||
                                 (which > 0 && which >= background_field((int32_t)of, RG_BG_SHOWABLE_MAPS))))
    rg_state_refuse_damaged("a background holds a map it does not have");
  free(cells_now[background].cells);
  cells_now[background] = (background_cells){(int32_t)which, (int32_t)of, NULL};
  scrolls[background] = (background_scroll){(int32_t)n[3], (int32_t)n[4]};
  from_corner[background] = n[5] != 0;
  colors_told[background] = n[6];
  boxes[background] = (background_box){n[7] != 0, (int32_t)n[8], (int32_t)n[9], (int32_t)n[10], (int32_t)n[11]};
  turns[background] = (background_turn){n[12] != 0, (int32_t)n[13], (int32_t)n[14], (int32_t)n[15], (int32_t)n[16]};
  bar_tops[background] = (int32_t)n[17];
  bar_placed[background] = n[18] != 0;
  bar_covers[background] = n[19] != 0;
  bend_lines_kept[background] = n[STATE_BENDS_KEPT] != 0;
}

/* rg_hook_visit_state: the scenery up and the changes waiting, then what each background's name
 * keeps, the cells of its own copy where it has one, and the lines of its bends where they were
 * worked out (Computer::StateFields "tiled" and the rest). Everything is visited by the entry that
 * keeps the name, so the slots of the other entries go as they are, unused. */
static void rg_tiled_visit_state(void) {
  int reading = rg_state_reading();
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];

  int64_t counts[] = {any_from_corner, corners_expired, shown_count, held_tile_count};
  rg_state_numbers("tiled", counts, 4);
  if (counts[2] < 0 || counts[2] >= MOST_SCENERY_PUT_UP || counts[3] < 0 || counts[3] > RG_HELD_TILES_ROOM)
    rg_state_refuse_damaged("the scenery holds more than it can");
  any_from_corner = counts[0] != 0;
  corners_expired = counts[1] != 0;

  /* The list of scenery up is emptied and put up again entry by entry, which grows its room to fit. */
  int64_t *shown = rg_state_room(counts[2]);
  if (!reading)
    for (int32_t i = 0; i < shown_count; i++) shown[i] = shown_backgrounds[i];
  rg_state_numbers("tiled.shown", shown, (int32_t)counts[2]);
  shown_count = 0;
  for (int64_t i = 0; i < counts[2]; i++) {
    if (shown[i] < 0 || shown[i] >= backgrounds) rg_state_refuse_damaged("the scenery up names a background the game does not have");
    remember_put_up((int32_t)shown[i]);
  }
  free(shown);

  int64_t held[HELD_TILE_NUMBERS * RG_HELD_TILES_ROOM];
  if (!reading)
    for (int32_t i = 0; i < held_tile_count; i++) {
      int64_t *change = held + HELD_TILE_NUMBERS * i;
      change[0] = held_tiles[i].background, change[1] = held_tiles[i].col, change[2] = held_tiles[i].row, change[3] = held_tiles[i].tile;
    }
  rg_state_numbers("tiled.held", held, HELD_TILE_NUMBERS * (int32_t)counts[3]);
  held_tile_count = (int32_t)counts[3];
  for (int32_t i = 0; i < held_tile_count; i++) {
    const int64_t *change = held + HELD_TILE_NUMBERS * i;
    if (change[0] < 0 || change[0] >= backgrounds) rg_state_refuse_damaged("a tile change waits for a background the game does not have");
    held_tiles[i] = (held_tile){(int32_t)change[0], (int32_t)change[1], (int32_t)change[2], (int32_t)change[3]};
  }

  int64_t *per_background = rg_state_room((int64_t)backgrounds * BACKGROUND_STATE_NUMBERS);
  if (!reading)
    for (int32_t bg = 0; bg < backgrounds; bg++) background_state_numbers(bg, per_background + bg * BACKGROUND_STATE_NUMBERS);
  rg_state_numbers("tiled.backgrounds", per_background, backgrounds * BACKGROUND_STATE_NUMBERS);
  if (reading)
    for (int32_t bg = 0; bg < backgrounds; bg++) read_background_state(bg, per_background + bg * BACKGROUND_STATE_NUMBERS);

  int64_t own_cells = 0, bent_lines = 0;
  for (int32_t bg = 0; bg < backgrounds; bg++) {
    const int64_t *numbers = per_background + bg * BACKGROUND_STATE_NUMBERS;
    own_cells += own_copy_cell_count(numbers);
    if (numbers[STATE_BENDS_KEPT]) bent_lines += RG_SCREEN_HEIGHT;
  }
  if (own_cells > INT32_MAX) rg_state_refuse_damaged("the backgrounds hold more cells than they can");

  /* Every own copy, one after another, then each given back to its background on reading. */
  int64_t *cells = rg_state_room(own_cells), at = 0;
  for (int32_t bg = 0; bg < backgrounds; bg++) {
    int64_t count = own_copy_cell_count(per_background + bg * BACKGROUND_STATE_NUMBERS);
    if (!reading)
      for (int64_t i = 0; i < count; i++) cells[at + i] = cells_now[bg].cells[i];
    at += count;
  }
  rg_state_numbers("tiled.cells", cells, (int32_t)own_cells);
  at = 0;
  for (int32_t bg = 0; reading && bg < backgrounds; bg++) {
    if (!per_background[bg * BACKGROUND_STATE_NUMBERS + STATE_HAS_OWN_CELLS]) continue;
    int64_t count = own_copy_cell_count(per_background + bg * BACKGROUND_STATE_NUMBERS);
    int16_t *copy = malloc((size_t)(count ? count : 1) * sizeof *copy);
    if (!copy) rg_fault("no memory left for a background's own copy of its map");
    for (int64_t i = 0; i < count; i++) copy[i] = (int16_t)cells[at + i];
    cells_now[bg].cells = copy;
    at += count;
  }
  free(cells);

  /* Each bend worked out, a screen's lines at a time, the same way. */
  int64_t *lines = rg_state_room(bent_lines);
  at = 0;
  for (int32_t bg = 0; bg < backgrounds; bg++) {
    if (!per_background[bg * BACKGROUND_STATE_NUMBERS + STATE_BENDS_KEPT]) continue;
    if (!reading)
      for (int32_t py = 0; py < RG_SCREEN_HEIGHT; py++) lines[at + py] = bend_lines[bg][py];
    at += RG_SCREEN_HEIGHT;
  }
  rg_state_numbers("tiled.bends", lines, (int32_t)bent_lines);
  at = 0;
  for (int32_t bg = 0; reading && bg < backgrounds; bg++) {
    if (!per_background[bg * BACKGROUND_STATE_NUMBERS + STATE_BENDS_KEPT]) continue;
    for (int32_t py = 0; py < RG_SCREEN_HEIGHT; py++) bend_lines[bg][py] = (int32_t)lines[at + py];
    at += RG_SCREEN_HEIGHT;
  }
  free(lines);
  free(per_background);
}
