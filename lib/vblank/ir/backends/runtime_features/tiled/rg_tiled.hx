/*
 * Scenery drawn from tiles (Reference @bg_shown and the rest): backgrounds and status bars, the maps they show
 * and the cells the game changes, their scroll, turn, bends and boxes, the order a stack of layers puts them in,
 * and a scene's scenery coming down. A runtime feature (backends/runtime_features.rb): joined into the runtime's
 * class after rg_screen.hx for a game that declares a background, so it reads the screen's own state and painters
 * as if it were written there. This is rg_tiled.js written again, function for function.
 *
 * Left out, because the Flash build has neither yet: a tile as drawn of a background read from the start file,
 * and the state image (rg_tiled_visit_state stops the game in plain words).
 */

static inline var RG_EVERY_SCENE:Int = -1;
static inline var RG_NOT_A_BAR:Int = -1;
static inline var RG_MAX_BACKGROUNDS:Int = 64;
static inline var RG_BG_TILE_W:Int = 0;
static inline var RG_BG_TILE_H:Int = 1;
static inline var RG_BG_FIRST_MAP:Int = 2;
static inline var RG_BG_SHOWABLE_MAPS:Int = 3;
static inline var RG_BG_KEPT_BY:Int = 4;
static inline var RG_BG_NEVER_WRAPS:Int = 5;
static inline var RG_BG_TILES_START:Int = 6;
static inline var RG_BG_SCENE:Int = 7;
static inline var RG_BG_LEVEL:Int = 8;
static inline var RG_BG_ON_ARRIVAL:Int = 9;
static inline var RG_BG_STACK_PLACE:Int = 10;
static inline var RG_BG_SEE_THROUGH:Int = 11;
static inline var RG_BG_BENT:Int = 12;
static inline var RG_BG_FADE_PLACE:Int = 13;
static inline var RG_BG_TILES:Int = 14;
static inline var RG_BG_COLOR_STEPS:Int = 15;
static inline var RG_BG_IN_BLOCKS:Int = 16;
static inline var RG_BG_CAN_TURN:Int = 17;
static inline var RG_BG_PAINTED:Int = 18;
static inline var RG_BG_RUN_COLORS:Int = 19;
static inline var RG_BG_BAR_TOP:Int = 20;
static inline var RG_BG_ABOVE_ROW:Int = 21;
static inline var RG_BG_ALONE:Int = 22;
static inline var RG_BG_FRONT:Int = 23;
static inline var RG_BG_PLACES:Int = 24;
static inline var RG_BG_TABLES:Int = 25;
static inline var RG_BG_FIELDS:Int = 26;
static inline var RG_NOT_IN_FRONT:Int = -1;
static inline var RG_SHOWN_WITH_OTHERS:Int = 0;
static inline var RG_SHOWN_ALONE:Int = 1;
static inline var RG_SHOWN_WITHOUT_SPRITES:Int = 2;
static inline var RG_CELL_EMPTY:Int = -1;
static inline var RG_NOT_PAINTED:Int = -1;
static inline var RG_MAP_CELLS:Int = 0;
static inline var RG_MAP_COLS:Int = 1;
static inline var RG_MAP_ROWS:Int = 2;
static inline var RG_MAP_GRID_COLS:Int = 3;
static inline var RG_MAP_GRID_ROWS:Int = 4;
static inline var RG_MAP_FIELDS:Int = 5;

static function background_field(background:Int, field:Int):Int { return rg_game_backgrounds[background * RG_BG_FIELDS + field]; }

/* A background is painted onto a sheet of its own first when it is laid on the picture a part at a time: inside a
 * box it is held to, or in blocks (Reference#paint_scenery_in_blocks). While +onto_sheet+ is set the background
 * painters land there, as stored and with no blend, and every row shows the map row +rows_tall+ rows above it at
 * most, the top of its block. */
static inline var NOTHING_ON_SHEET:Int = -1;
static var sheet:Vector<Int> = new Vector<Int>(RG_CELLS);
static var onto_sheet:Int = 0;
static var rows_tall:Int = 1;

/* The box a background is held to (Reference @bg_box), by the entry that keeps its name. */
static var boxes:Array<RgBox> = [for (i in 0...RG_MAX_BACKGROUNDS) new RgBox()];

/* Scenery up, in the order it went up (Reference @bg_shown), one entry for every time a background is put up. */
static var shown_backgrounds:Array<Int> = [];

/* What the game does to a background, kept at the entry that keeps it for the name. colors_told is one more than
 * the step of colours the game last named, nought for none. */
static var cells_now:Array<RgCells> = [for (i in 0...RG_MAX_BACKGROUNDS) new RgCells()];
static var scrolls:Array<RgScroll> = [for (i in 0...RG_MAX_BACKGROUNDS) new RgScroll()];
static var colors_told:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];
static var turns:Array<RgTurn> = [for (i in 0...RG_MAX_BACKGROUNDS) new RgTurn()];

/* The backgrounds put up this pass, shown from their top-left corner whatever their scroll (Reference
 * @bg_from_corner), whether there are any, and whether their pass has ended (Reference @bg_corners_expired). */
static var from_corner:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];
static var any_from_corner:Int = 0;
static var corners_expired:Int = 0;

/* --- scenery --- */

static function keeper_of(background:Int):Int { return background_field(background, RG_BG_KEPT_BY); }

/* Reference#background_up: the declaration of this background's name a line naming it means. */
static function declaration_up(background:Int):Int {
  var keeper = keeper_of(background);
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (keeper_of(bg) == keeper && showing(bg)) return bg;
  }
  return keeper;
}

/* Reference#background_swap: which set of its tiles this entry is drawn from now. */
static function tile_set_now(background:Int):Int {
  var step = colors_told[keeper_of(background)] - 1;
  return step >= 0 && step < background_field(background, RG_BG_COLOR_STEPS) ? step + 1 : 0;
}

/* Reference#scroll_shown: where a background's window sits on the display now. */
static function scroll_shown(background:Int):RgScroll {
  var keeper = keeper_of(background);
  return from_corner[keeper] != 0 ? new RgScroll(0, 0) : scrolls[keeper];
}

/* Reference#forget_expired_corners. A frame that moved nothing builds nothing, so the corners going is itself a
 * change to the picture, and asks for it. */
static function forget_expired_corners():Void {
  if (corners_expired == 0) return;
  var were_shown_from_corners = any_from_corner;
  corners_expired = 0;
  for (i in 0...RG_MAX_BACKGROUNDS) from_corner[i] = 0;
  any_from_corner = 0;
  if (were_shown_from_corners != 0 && rebuilt_whole() != 0) request_repaint();
}

/* Reference#mark_from_corner */
static function mark_from_corner(background:Int):Void {
  forget_expired_corners();
  from_corner[keeper_of(background)] = 1;
  any_from_corner = 1;
}

/* Map number +which+ of a background's own maps, as where its entry starts in rg_game_maps. */
static function map_entry(background:Int, which:Int):Int { return RG_MAP_FIELDS * (background_field(background, RG_BG_FIRST_MAP) + which); }

/* Reference#map_of: the map a background's cells hold now. */
static function map_now(background:Int):Int {
  var now = cells_now[keeper_of(background)];
  return now.cells != null ? map_entry(now.of, now.which) : map_entry(background, 0);
}

static function map_cols(background:Int):Int { return rg_game_maps[map_now(background) + RG_MAP_COLS]; }
static function map_rows(background:Int):Int { return rg_game_maps[map_now(background) + RG_MAP_ROWS]; }

static function in_map(background:Int, row:Int, col:Int):Bool {
  return row >= 0 && row < map_rows(background) && col >= 0 && col < map_cols(background);
}

static function cell_place(background:Int, row:Int, col:Int):Int { return row * map_cols(background) + col; }

/* Reference#map_of: what a cell holds NOW. Below nought where it holds no tile. */
static function map_cell(background:Int, row:Int, col:Int):Int {
  if (!in_map(background, row, col)) return RG_CELL_EMPTY;
  var own = cells_now[keeper_of(background)].cells;
  if (own != null) return own[cell_place(background, row, col)];
  return rg_game_map_cells[rg_game_maps[map_now(background) + RG_MAP_CELLS] + cell_place(background, row, col)];
}

/* The name's cells become the run's own copy of map number +which+ of the maps of the declaration up now. */
static function copy_map(background:Int, which:Int):Void {
  var keeper = keeper_of(background);
  var up = declaration_up(background);
  var map = map_entry(up, which);
  var start = rg_game_maps[map + RG_MAP_CELLS];
  var count = rg_game_maps[map + RG_MAP_COLS] * rg_game_maps[map + RG_MAP_ROWS];
  var own = new RgCells();
  own.which = which;
  own.of = up;
  own.cells = new Vector<Int>(count > 0 ? count : 1);
  for (i in 0...count) own.cells[i] = rg_game_map_cells[start + i];
  cells_now[keeper] = own;
}

static function forget_own_cells(background:Int):Void { cells_now[keeper_of(background)] = new RgCells(); }

/* The start of Reference#take_over. */
static function rg_background_forget_cells(background:Int):Void { forget_own_cells(background); }

/* Whether a cell showing tile +cell+ is in front of the sprites. */
static function cell_in_front(background:Int, cell:Int):Bool {
  return rg_game_tiles_in_front[tiles_painted_only + cell] != 0;
}

/* One pixel of tile +which+ of the run +run+ the game paints. */
static function run_pixel(background:Int, run:Int, which:Int, tx:Int, ty:Int):Int {
  /* A big tile is kept as four squares, left to right and then down. */
  if (background_field(background, RG_BG_TILE_W) == 2 * RUN_TILE_SIDE) {
    which = which * 4 + Std.int(ty / RUN_TILE_SIDE) * 2 + Std.int(tx / RUN_TILE_SIDE);
    tx = tx % RUN_TILE_SIDE;
    ty = ty % RUN_TILE_SIDE;
  }
  var place = painted_places_at(places_of(run) + which * RUN_TILE_PIXELS + ty * RUN_TILE_SIDE + tx);
  var set = tile_set_now(background) * rg_game_picture_sizes[RG_SIZE_RUNS] + run;
  return rg_game_run_colors[background_field(background, RG_BG_RUN_COLORS) + set * PLACES_IN_RUN_COLORS + place];
}

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel). */
static function tile_pixel(background:Int, cell:Int, tx:Int, ty:Int):Int {
  var painted = background_field(background, RG_BG_PAINTED);
  if (painted != RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] != RG_NOT_PAINTED) {
    return run_pixel(background, rg_game_painted_tiles[painted + 2 * cell], rg_game_painted_tiles[painted + 2 * cell + 1], tx, ty);
  }
  var tile_w = background_field(background, RG_BG_TILE_W);
  var tile_h = background_field(background, RG_BG_TILE_H);
  var tile = tile_set_now(background) * background_field(background, RG_BG_TILES) + cell;
  return rg_game_tile_pixels[background_field(background, RG_BG_TILES_START) + tile * tile_w * tile_h + ty * tile_w + tx];
}

/* Reference#grid_repeats: how many times the grid is seen along one side of the screen. */
static function grid_repeats(background:Int, grid_cells:Int, screen_side:Int):Int {
  if (background_field(background, RG_BG_NEVER_WRAPS) != 0 || background_field(background, RG_BG_TILE_W) != 8 ||
      background_field(background, RG_BG_TILE_H) != 8) return 1;
  return Std.int(Math.ceil(screen_side / (grid_cells * 8)));
}

/* The map onto the picture with its corner at (left, top), cell by cell. */
static function stamp_map_at(background:Int, left:Int, top:Int):Void {
  var tile_w = background_field(background, RG_BG_TILE_W);
  var tile_h = background_field(background, RG_BG_TILE_H);
  var rows = map_rows(background);
  var cols = map_cols(background);
  for (row in 0...rows) {
    for (col in 0...cols) {
      var cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (ty in 0...tile_h) {
        for (tx in 0...tile_w) {
          var color = tile_pixel(background, cell, tx, ty);
          if (color != RG_SEE_THROUGH) set_pixel(left + col * tile_w + tx, top + row * tile_h + ty, color);
        }
      }
    }
  }
}

/* Reference#stamp_background */
static function rg_background_stamp(background:Int):Void {
  /* A status bar is painted from its own top as the view is built, and a background held above a row stops at it,
   * and one under a background shown alone starts there. */
  if (background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR || boxes[keeper_of(background)].held != 0 ||
      row_held_alone_by_another(background) != RG_NOT_A_BAR) {
    request_repaint();
    return;
  }
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  var map = map_now(background);
  var grid_cols = rg_game_maps[map + RG_MAP_GRID_COLS];
  var grid_rows = rg_game_maps[map + RG_MAP_GRID_ROWS];
  var across = grid_repeats(background, grid_cols, RG_SCREEN_WIDTH);
  var down = grid_repeats(background, grid_rows, RG_SCREEN_HEIGHT);
  for (round_down in 0...down) {
    for (round_across in 0...across) stamp_map_at(background, round_across * grid_cols * 8, round_down * grid_rows * 8);
  }
  mix_nothing();
}

static function stack_place(background:Int):Int { return background_field(background, RG_BG_STACK_PLACE); }

/* Reference#behind?: only when both named a layer. */
static function behind(a:Int, b:Int):Bool {
  return stack_place(a) != RG_NO_LAYER && stack_place(b) != RG_NO_LAYER && stack_place(a) < stack_place(b);
}

static function remember_put_up(background:Int):Void { shown_backgrounds.push(background); }

static function in_order_asked(entry:Int, over:Int):Bool { return over < 0 || behind(over, entry); }

/* Where the last entry for +background+ lands once the entries asked for are put in the order the stack asks for
 * (IR::Stacking.order_by_stack), or -1 when it has no entry. */
static function last_place_in_stack_order(background:Int, over:Int):Int {
  var place = stack_place(background);
  var at = -1;
  var last = -1;
  var further_back = 0;
  var in_its_layer = 0;
  var in_its_layer_by_last = 0;
  for (entry in shown_backgrounds) {
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

  var nth = further_back + in_its_layer_by_last - 1;
  var named = -1;
  at = -1;
  for (entry in shown_backgrounds) {
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) != RG_NO_LAYER) {
      named++;
      if (named == nth) return at;
    }
  }
  return -1;
}

/* Reference#in_stack_order over the scenery that is up, each stamped once in that order. */
static function stamp_in_stack_order(over:Int):Void {
  if (over >= 0 && stack_place(over) == RG_NO_LAYER) return;
  var backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  var lands:Array<Int> = [];
  for (bg in 0...backgrounds) lands.push(last_place_in_stack_order(bg, over));
  while (true) {
    var next = -1;
    for (bg in 0...backgrounds) {
      if (lands[bg] >= 0 && (next < 0 || lands[bg] < lands[next])) next = bg;
    }
    if (next < 0) return;
    rg_background_stamp(next);
    lands[next] = -1;
  }
}

/* Reference#put_up_background */
static function rg_background_put_up(background:Int):Void {
  /* A change still waiting to this background's name was made to cells put up again now; the changes to every
   * other background are kept, in the order made. */
  var keeper = keeper_of(background);
  held_tiles = held_tiles.filter(function(change) return keeper_of(change.background) != keeper);
  if (background_field(background, RG_BG_ON_ARRIVAL) != 0) {
    forget_own_cells(background);
    boxes[keeper_of(background)].held = 0; /* its scene puts it up showing everywhere */
  }
  remember_put_up(background);
  mark_from_corner(background);
  scenery_kept = 0;
  if (turns[keeper_of(background)].turned != 0 || background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR || bar_showing() >= 0 ||
      boxes[keeper_of(background)].held != 0 || placed_fade_in_picture()) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
  stamp_in_stack_order(background);
}

/* Reference#exec_affine_background */
static function rg_background_turn(background:Int, angle:Int, size:Int, pivot_x:Int, pivot_y:Int):Void {
  var turn = new RgTurn();
  turn.turned = 1;
  turn.angle = floor_mod(angle, 360);
  turn.size = size;
  turn.pivot_x = pivot_x;
  turn.pivot_y = pivot_y;
  turns[keeper_of(background)] = turn;
  request_repaint();
}

/* Reference#showing_scenery */
static function showing(background:Int):Bool {
  var scene = background_field(background, RG_BG_SCENE);
  return scene == RG_EVERY_SCENE || scene == current_scene;
}

/* Reference#exec_scroll_background. This builds the view again only when the scroll the picture shows is not the
 * one it was built with, so a frame that sets the same scroll again costs nothing. What the picture shows is what
 * scroll_shown answers, which for a background put up this pass is its corner, so a scroll set over a corner is a
 * change even where the number written is the one already stored. */
static function rg_background_scroll(background:Int, x:Int, y:Int):Void {
  var before = scroll_shown(background);
  var before_x = before.x;
  var before_y = before.y;
  scrolls[keeper_of(background)] = new RgScroll(x, y);
  if (placing_at_pass_end == 0) from_corner[keeper_of(background)] = 0;
  var after = scroll_shown(background);
  if (after.x != before_x || after.y != before_y) request_repaint();
  else skip_repaint();
}

/* Where each status bar was last placed, by the entry that keeps its name, and whether it has been (Reference @bar_top). */
static var bar_tops:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];
static var bar_placed:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];

/* Reference#exec_place_bar */
static function rg_place_bar(background:Int, top:Int):Void {
  bar_tops[keeper_of(background)] = clamp_number(top, 0, RG_SCREEN_HEIGHT);
  bar_placed[keeper_of(background)] = 1;
  if (placing_at_pass_end == 0) from_corner[keeper_of(background)] = 0;
  request_repaint();
}

/* Reference#exec_box_background and #screen_box: a box with nothing on the screen is an empty one at the corner. */
static function rg_background_box(background:Int, x:Int, y:Int, width:Int, height:Int, held:Int):Void {
  var box = boxes[keeper_of(background)];
  if (held == 0) {
    box.held = 0;
  } else {
    box.held = 1;
    box.left = 0;
    box.top = 0;
    box.right = 0;
    box.bottom = 0;
    if (width > 0 && height > 0) {
      var left = clamp_number(x, 0, RG_SCREEN_WIDTH);
      var right = clamp_number(rg_held_sum(x, width), 0, RG_SCREEN_WIDTH);
      var top = clamp_number(y, 0, RG_SCREEN_HEIGHT);
      var bottom = clamp_number(rg_held_sum(y, height), 0, RG_SCREEN_HEIGHT);
      if (right > left && bottom > top) {
        box.left = left;
        box.top = top;
        box.right = right;
        box.bottom = bottom;
      }
    }
  }
  request_repaint();
}

/* Which status bars hide the sprites from their top down, by the same entry (Reference @bar_covers). */
static var bar_covers:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];

static function rg_bar_covers(background:Int, covers:Int):Void {
  bar_covers[keeper_of(background)] = covers != 0 ? 1 : 0;
  request_repaint();
}

/* Reference#bar_top_shown */
static function bar_top_shown(bar:Int):Int {
  var declared = clamp_number(background_field(bar, RG_BG_BAR_TOP), 0, RG_SCREEN_HEIGHT);
  var keeper = keeper_of(bar);
  return from_corner[keeper] != 0 || bar_placed[keeper] == 0 ? declared : bar_tops[keeper];
}

/* Reference#bar_showing: the status bar on screen, or -1. */
static function bar_showing():Int {
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (showing(bg) && background_field(bg, RG_BG_BAR_TOP) != RG_NOT_A_BAR) return bg;
  }
  return -1;
}

/* Reference#scenery_rows */
static function scenery_rows():Int {
  var bar = bar_showing();
  return bar < 0 ? RG_SCREEN_HEIGHT : bar_top_shown(bar);
}

/* Reference#rows_shown_of */
static function rows_shown_of(background:Int):Int {
  var above = background_field(background, RG_BG_ABOVE_ROW);
  var rows = scenery_rows();
  return above == RG_NOT_A_BAR ? rows : (rows < above ? rows : above);
}

/* Reference#row_held_alone_by_another: the row of a background up and shown alone above it, where +background+ is
 * another, or RG_NOT_A_BAR. */
static function row_held_alone_by_another(background:Int):Int {
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (bg != background && showing(bg) && background_field(bg, RG_BG_ALONE) != 0) return background_field(bg, RG_BG_ABOVE_ROW);
  }
  return RG_NOT_A_BAR;
}

/* Reference#exec_set_tile_block, a block put back. */
static function rg_background_restore_cells(background:Int, col:Int, row:Int, across:Int, down:Int):Void {
  var cells = cells_now[keeper_of(background)].cells;
  if (cells == null) return;
  var declared = rg_game_maps[map_entry(declaration_up(background), 0) + RG_MAP_CELLS];
  var cols = map_cols(background);
  var rows = map_rows(background);
  var past_row = row + down < rows ? row + down : rows;
  var past_col = col + across < cols ? col + across : cols;
  var changed = false;
  for (r in (row > 0 ? row : 0)...past_row) {
    for (c in (col > 0 ? col : 0)...past_col) {
      var at = r * cols + c;
      if (cells[at] == rg_game_map_cells[declared + at]) continue;
      cells[at] = rg_game_map_cells[declared + at];
      changed = true;
    }
  }
  if (changed) request_repaint();
}

static function rg_background_set_tile(background:Int, col:Int, row:Int, tile:Int):Void {
  /* A tile only another scene's declaration of the name has changes nothing here. */
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (cells_now[keeper_of(background)].cells == null) copy_map(background, 0);
  if (!in_map(background, row, col)) return;
  var cells = cells_now[keeper_of(background)].cells;
  var at = cell_place(background, row, col);
  if (cells[at] == tile) return;
  cells[at] = tile;
  request_repaint();
}

/* The cell changes of backgrounds declared `held: true`, waiting for rg_show_held_tiles (Reference's @held_tiles),
 * in the order the game made them. */
static var held_tiles:Array<RgHeldTile> = [];

/* Reference#exec_set_tile, held: the change waits, its cell worked out now. With +most+ waiting, everything waiting
 * goes in first. */
static function rg_background_hold_tile(background:Int, col:Int, row:Int, tile:Int, most:Int):Void {
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (held_tiles.length >= most) rg_show_held_tiles();
  held_tiles.push(new RgHeldTile(background, col, row, tile));
}

/* Reference#exec_show_held_tiles */
static function rg_show_held_tiles():Void {
  var waiting = held_tiles;
  held_tiles = [];
  for (change in waiting) rg_background_set_tile(change.background, change.col, change.row, change.tile);
}

static function rg_background_show_map(background:Int, which:Int):Void {
  if (which < 0 || which >= background_field(declaration_up(background), RG_BG_SHOWABLE_MAPS)) return;
  copy_map(background, which);
  request_repaint();
}

static function rg_background_draw_with(background:Int, which:Int):Void {
  colors_told[keeper_of(background)] = which < 0 ? 0 : which + 1;
  request_repaint();
}

/* rg_background_follow in the native runtime: the tiles a background draws from one of several lists it follows
 * are copied from set number +set+ of its tiles over the ones the picture is drawn from. */
static function rg_background_follow(rules:Vector<Int>, set:Int):Void {
  var background = rules[1];
  var count = rules[2];
  var tile_size = background_field(background, RG_BG_TILE_W) * background_field(background, RG_BG_TILE_H);
  var start = background_field(background, RG_BG_TILES_START);
  var set_size = background_field(background, RG_BG_TILES) * tile_size;
  var changed = false;
  for (i in 0...count) {
    var to = start + rules[3 + i] * tile_size;
    var from = to + set * set_size;
    for (at in 0...tile_size) {
      if (rg_game_tile_pixels[to + at] == rg_game_tile_pixels[from + at]) continue;
      rg_game_tile_pixels[to + at] = rg_game_tile_pixels[from + at];
      changed = true;
    }
  }
  if (changed) request_repaint();
}

/* While the cells in front of the sprites are painted again (paint_cells_in_front), where the background's tiles
 * start in rg_game_tiles_in_front, a byte a tile, 1 for one in front; and RG_NOT_IN_FRONT the rest of the time,
 * when every tile is painted. */
static var tiles_painted_only:Int = RG_NOT_IN_FRONT;

static function paint_map_pixel(background:Int, mx:Int, my:Int, px:Int, py:Int):Void {
  var tile_w = background_field(background, RG_BG_TILE_W);
  var tile_h = background_field(background, RG_BG_TILE_H);
  var cell = map_cell(background, Std.int(my / tile_h), Std.int(mx / tile_w));
  if (cell < 0) return;
  if (tiles_painted_only != RG_NOT_IN_FRONT && !cell_in_front(background, cell)) return;
  var color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
  if (color == RG_SEE_THROUGH) return;
  if (onto_sheet != 0) sheet[py * RG_SCREEN_WIDTH + px] = color;
  else lay_scenery(px, py, color);
}

/* One row of the screen from one row of a background's map. The screen's pixel px shows map column off_x + px,
 * taken round at +wrap_w+ where the map wraps, or not at all (0) where it does not; +my+ is not below nought. A
 * tile is the same for every pixel of its row, so the cell, its tile and where its row starts are looked up once
 * for each tile the row crosses, and its pixels are read in turn. A painted tile is read the slow way (tile_pixel). */
static function paint_map_row(background:Int, my:Int, off_x:Int, wrap_w:Int, py:Int):Void {
  var tile_w = background_field(background, RG_BG_TILE_W);
  var tile_h = background_field(background, RG_BG_TILE_H);
  var map = map_now(background);
  var cols = rg_game_maps[map + RG_MAP_COLS];
  var row = Std.int(my / tile_h);
  if (row >= rg_game_maps[map + RG_MAP_ROWS]) return;
  var own = cells_now[keeper_of(background)].cells;
  var cells:Vector<Int> = own != null ? own : rg_game_map_cells;
  var row_start = (own != null ? 0 : rg_game_maps[map + RG_MAP_CELLS]) + row * cols;
  var ty = my % tile_h;
  var tiles = background_field(background, RG_BG_TILES);
  var painted = background_field(background, RG_BG_PAINTED);
  var set_start = background_field(background, RG_BG_TILES_START) + tile_set_now(background) * tiles * tile_w * tile_h + ty * tile_w;
  var plain = paint_fade == null && mixing == 0;
  var keeps_without_sprites = sprites_seen_through() != 0;
  var row_at = py * RG_SCREEN_WIDTH;
  var px = 0;
  while (px < RG_SCREEN_WIDTH) {
    var mx = off_x + px;
    if (wrap_w != 0) mx = mx % wrap_w;
    if (mx < 0) { /* only where the map does not wrap: nothing until the map's left edge */
      px -= mx;
      continue;
    }
    var col = Std.int(mx / tile_w);
    var tx = mx - col * tile_w;
    var run = tile_w - tx < RG_SCREEN_WIDTH - px ? tile_w - tx : RG_SCREEN_WIDTH - px;
    var cell = col < cols ? cells[row_start + col] : RG_CELL_EMPTY;
    if (cell >= 0 && (tiles_painted_only == RG_NOT_IN_FRONT || rg_game_tiles_in_front[tiles_painted_only + cell] != 0)) {
      var slow = painted != RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] != RG_NOT_PAINTED;
      var from = set_start + cell * tile_w * tile_h + tx;
      for (i in 0...run) {
        var color = slow ? tile_pixel(background, cell, tx + i, ty) : rg_game_tile_pixels[from + i];
        if (color == RG_SEE_THROUGH) continue;
        var at = row_at + px + i;
        if (onto_sheet != 0) {
          sheet[at] = color;
        } else if (plain) {
          pixels[at] = color & 0xFFFF;
          picture_mixes.is_mixed[at] = 0;
          if (keeps_without_sprites) picture_without_sprites[at] = pixels[at];
        } else {
          lay_scenery(px + i, py, color);
        }
      }
    }
    px += run;
  }
}

static function row_drawn_from(py:Int):Int { return py - (py % rows_tall); }

/* --- bends: what each row of a background is moved by (scroll_each_row) --- */

static var asked_bend_background:Int = NOBODY_ASKED;
static var asked_bend_py:Int = 0;
static var asked_bend_offset:Int = 0;

static function rg_bend_asked(background:Int):Int { return background == asked_bend_background ? 1 : 0; }
static function rg_bend_line():Int { return asked_bend_py; }
static function rg_bend_answer(offset:Int):Void { asked_bend_offset = offset; }

static var bend_lines:Array<Vector<Int>> = [for (i in 0...RG_MAX_BACKGROUNDS) new Vector<Int>(RG_SCREEN_HEIGHT)];
static var bend_lines_kept:Array<Int> = [for (i in 0...RG_MAX_BACKGROUNDS) 0];

/* Reference#run_bend_for_row */
static function run_bend_for_line(keeper:Int, py:Int):Int {
  asked_bend_background = keeper;
  asked_bend_py = py;
  rg_game_bend_offsets();
  asked_bend_background = NOBODY_ASKED;
  return asked_bend_offset;
}

static function rg_bend_work_out(background:Int, first_line:Int, past_line:Int):Void {
  var keeper = keeper_of(background);
  for (py in first_line...past_line) bend_lines[keeper][py] = run_bend_for_line(keeper, py);
  bend_lines_kept[keeper] = 1;
}

/* Reference#work_out_bends */
static function rg_screen_work_out_bends():Void {
  rg_game_work_out_bends();
  if (frames_begun != 0) request_repaint();
}

/* Reference#bend_offset_at */
static function bend_at(background:Int, py:Int):Int {
  if (background_field(background, RG_BG_BENT) == 0) return 0;
  var keeper = keeper_of(background);
  if (bend_lines_kept[keeper] != 0) return bend_lines[keeper][py];
  return frames_begun != 0 ? 0 : run_bend_for_line(keeper, py);
}

/* Reference#paint_streamed_background_window */
static function paint_window_without_wrapping(background:Int):Void {
  var map_h = map_rows(background) * background_field(background, RG_BG_TILE_H);
  var scroll = scroll_shown(background);
  for (py in 0...rows_shown_of(background)) {
    var my = scroll.y + row_drawn_from(py);
    if (my < 0 || my >= map_h) continue;
    paint_map_row(background, my, scroll.x + bend_at(background, py), 0, py);
  }
}

/* Reference#paint_background_window, for a background never turned */
static function paint_window(background:Int):Void {
  if (background_field(background, RG_BG_NEVER_WRAPS) != 0) {
    paint_window_without_wrapping(background);
    return;
  }
  var map = map_now(background);
  var map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * background_field(background, RG_BG_TILE_W);
  var map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * background_field(background, RG_BG_TILE_H);
  if (map_w == 0 || map_h == 0) return;
  var scroll = scroll_shown(background);
  var off_y = floor_mod(scroll.y, map_h);
  for (py in 0...rows_shown_of(background)) {
    var off_x = floor_mod(scroll.x + bend_at(background, py), map_w);
    paint_map_row(background, (off_y + row_drawn_from(py)) % map_h, off_x, map_w, py);
  }
}

/* Reference#paint_affine_background_window */
static function paint_turned_window(background:Int):Void {
  var tile_w = background_field(background, RG_BG_TILE_W);
  var tile_h = background_field(background, RG_BG_TILE_H);
  var map = map_now(background);
  var map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * tile_w;
  var map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * tile_h;
  if (map_w == 0 || map_h == 0) return;
  var turn = turns[keeper_of(background)];
  // A turned layer is placed by its turn, which putting it up leaves as it is.
  var scroll = scrolls[keeper_of(background)];
  var pivot_x = turn.pivot_x;
  var pivot_y = turn.pivot_y;
  var one_th = rg_game_turn_rules[1];
  var matrix = affine_matrix(turn.angle, turn.size);
  var turn_cos = matrix[0];
  var turn_sin = matrix[1];
  for (py in 0...scenery_rows()) {
    var dy = row_drawn_from(py) - pivot_y;
    for (px in 0...RG_SCREEN_WIDTH) {
      var dx = px - pivot_x;
      var mx = floor_mod(scroll.x + pivot_x + rg_floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      var my = floor_mod(scroll.y + pivot_y + rg_floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
      var cell = map_cell(background, Std.int(my / tile_h), Std.int(mx / tile_w));
      if (cell < 0) continue;
      var color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color == RG_SEE_THROUGH) continue;
      if (onto_sheet != 0) sheet[py * RG_SCREEN_WIDTH + px] = color;
      else set_pixel(px, py, color);
    }
  }
}

static function paint_background(background:Int):Void {
  if (turns[keeper_of(background)].turned != 0) paint_turned_window(background);
  else paint_window(background);
}

static function fill_sheet():Void {
  for (i in 0...RG_CELLS) sheet[i] = NOTHING_ON_SHEET;
}

/* Reference#paint_scenery_in_blocks: one background in blocks of +block+ pixels each way, by the display's own
 * rule, while the picture is shown in them (rg_hook_block_size). The blocks are fixed to the screen, and each
 * shows the colour the background has at the block's top left corner. A background held to a box keeps to the box
 * as it is laid (+box+, or null). A background that can turn is left one pixel wide at a size of two, so its rows
 * double and its columns do not (Reference#block_width_across). */
static function paint_scenery_in_blocks(background:Int, block:Int, box:RgBox):Void {
  fill_sheet();
  onto_sheet = 1;
  rows_tall = block;
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  var wide = background_field(background, RG_BG_CAN_TURN) != 0 && block == 2 ? 1 : block;
  for (py in 0...scenery_rows()) {
    for (px in 0...RG_SCREEN_WIDTH) {
      if (box != null && (px < box.left || px >= box.right || py < box.top || py >= box.bottom)) continue;
      var color = sheet[py * RG_SCREEN_WIDTH + px - (px % wide)];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_scenery_in_box: a background held to a box goes onto the sheet as it would onto the picture, and
 * only its pixels inside the box are laid on the picture. */
static function paint_scenery_in_box(background:Int, box:RgBox):Void {
  fill_sheet();
  onto_sheet = 1;
  paint_background(background);
  onto_sheet = 0;
  for (py in box.top...box.bottom) {
    for (px in box.left...box.right) {
      var color = sheet[py * RG_SCREEN_WIDTH + px];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_status_bar_rows: a row in a block that starts above the bar reads the bar's map above its first
 * row, where its grid comes round. */
static function paint_status_bar_rows(bar:Int):Void {
  var top = bar_top_shown(bar);
  var grid_h = rg_game_maps[map_now(bar) + RG_MAP_GRID_ROWS] * background_field(bar, RG_BG_TILE_H);
  for (py in top...RG_SCREEN_HEIGHT) {
    var my = row_drawn_from(py) - top;
    if (my < 0) {
      if (grid_h == 0) continue;
      my = floor_mod(my, grid_h);
    }
    for (px in 0...RG_SCREEN_WIDTH) paint_map_pixel(bar, px, my, px, py);
  }
}

/* Reference#paint_status_bar */
static function paint_status_bar(bar:Int):Void {
  var block = rg_hook_block_size();
  if (block == 1 || background_field(bar, RG_BG_IN_BLOCKS) == 0) {
    paint_status_bar_rows(bar);
    return;
  }
  fill_sheet();
  onto_sheet = 1;
  rows_tall = block;
  paint_status_bar_rows(bar);
  onto_sheet = 0;
  rows_tall = 1;
  for (py in bar_top_shown(bar)...RG_SCREEN_HEIGHT) {
    for (px in 0...RG_SCREEN_WIDTH) {
      var color = sheet[py * RG_SCREEN_WIDTH + px - (px % block)];
      if (color != NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_scenery: a background held to a box with nothing in it paints nothing; one the game has not left
 * as drawn is painted in blocks while the blocks are bigger than a pixel. Under a background shown alone above its
 * row, it is held to the rows from there down as if to a box (Reference#box_shown_of). */
static function paint_scenery(background:Int):Void {
  var shown_box = boxes[keeper_of(background)];
  var alone = row_held_alone_by_another(background);
  if (alone != RG_NOT_A_BAR) {
    if (shown_box.held != 0) {
      shown_box = shown_box.copy();
    } else {
      shown_box = new RgBox();
      shown_box.held = 1;
      shown_box.right = RG_SCREEN_WIDTH;
      shown_box.bottom = RG_SCREEN_HEIGHT;
    }
    if (shown_box.top < alone) shown_box.top = alone;
  }
  var box = shown_box.held != 0 ? shown_box : null;
  if (box != null && (box.right <= box.left || box.bottom <= box.top)) return;
  var block = rg_hook_block_size();
  if (block > 1 && background_field(background, RG_BG_IN_BLOCKS) != 0) paint_scenery_in_blocks(background, block, box);
  else if (box != null) paint_scenery_in_box(background, box);
  else paint_background(background);
}

/* Reference#set_blend_for, for scenery: what is painted next is mixed as the layer the background is in, and
 * faded unless a placed fade leaves it as drawn. */
static function blend_as_background(background:Int):Void {
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  fade_unless_left_as_drawn(background_field(background, RG_BG_FADE_PLACE));
}

/* --- the hooks it takes --- */

/* Reference#exec_screen: a screen of another kind wipes the scenery, and arriving on one drawn from tiles puts up
 * again what every such screen shows, as declared (#put_up_always_up). */
static function rg_tiled_screen_crossed(new_kind:Int):Void {
  shown_backgrounds = [];
  if (new_kind == RG_BITMAP) return;
  for (i in 0...rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]) {
    forget_own_cells(rg_game_always_up[i]);
    rg_background_put_up(rg_game_always_up[i]);
  }
}

/* The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its picture is
 * painted (Reference#forget_expired_corners). */
static function rg_tiled_frame_ended():Void {
  if (any_from_corner != 0) corners_expired = 1;
}

static function rg_tiled_repaint_requested():Void { forget_expired_corners(); }
static function rg_tiled_rebuild_checked():Void { forget_expired_corners(); }

/* The status bar's state while the view is rebuilt, from rg_tiled_repaint_began to rg_tiled_repaint_ending: the
 * bar on screen, or -1. */
static var bar_in_rebuild:Int = -1;

/* A status bar is painted first: no background is painted under it, so it is in front of all of them and every
 * sprite is painted over it. */
static function rg_tiled_repaint_began():Void {
  bar_in_rebuild = bar_showing();
  if (bar_in_rebuild < 0) return;
  blend_as_background(bar_in_rebuild);
  paint_status_bar(bar_in_rebuild);
}

static function rg_tiled_paint_level(level:Int):Void {
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (!showing(bg) || background_field(bg, RG_BG_LEVEL) != level) continue;
    blend_as_background(bg);
    paint_scenery(bg);
  }
}

/* Reference#paint_held_over_sprites: a background shown alone without sprites painted again over its rows, from the
 * backdrop up. */
static function paint_held_over_sprites(held_bg:Int):Void {
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  fill_cells(0, 0, RG_SCREEN_WIDTH, rows_shown_of(held_bg), backdrop);
  blend_as_background(held_bg);
  paint_scenery(held_bg);
}

/* Reference#paint_bar_over_sprites */
static function paint_bar_over_sprites(bar:Int):Void {
  var top = bar_top_shown(bar);
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  fill_cells(0, top, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT - top, backdrop);
  blend_as_background(bar);
  paint_status_bar(bar);
}

/* Reference#paint_cells_in_front */
static function paint_cells_in_front():Void {
  for (level in 0...rg_game_picture_sizes[RG_SIZE_DEPTHS]) {
    for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
      var front = background_field(bg, RG_BG_FRONT);
      if (front == RG_NOT_IN_FRONT || !showing(bg) || background_field(bg, RG_BG_LEVEL) != level) continue;
      blend_as_background(bg);
      tiles_painted_only = front;
      paint_scenery(bg);
      tiles_painted_only = RG_NOT_IN_FRONT;
    }
  }
}

/* The end of Reference#repaint_view */
static function rg_tiled_repaint_ending():Void {
  var bar = bar_in_rebuild;
  bar_in_rebuild = -1;
  paint_cells_in_front();
  if (bar >= 0 && bar_covers[keeper_of(bar)] != 0) paint_bar_over_sprites(bar);
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (showing(bg) && background_field(bg, RG_BG_ALONE) == RG_SHOWN_WITHOUT_SPRITES) {
      paint_held_over_sprites(bg);
      return;
    }
  }
}

/* Reference#scene_framebuffer: every background showing, stamped. */
static function rg_tiled_stamp_scenery():Void {
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (showing(bg)) rg_background_stamp(bg);
  }
}

static function rg_tiled_scenery_up():Bool { return shown_backgrounds.length > 0; }

/* Reference#layer_has_anything?, for scenery: a background showing now in that layer. */
static function rg_tiled_layer_holds_scenery(layer:Int):Bool {
  for (bg in 0...rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) {
    if (showing(bg) && background_field(bg, RG_BG_SEE_THROUGH) == layer) return true;
  }
  return false;
}

/* Reference#take_down_scenery: the last scene's own scenery comes down, and the picture goes back to the scenery
 * every screen shows. Answers whether any came down. */
static function rg_tiled_scene_take_down(brings_scenery:Int):Bool {
  var any_scene_owned = false;
  for (entry in shown_backgrounds) {
    if (background_field(entry, RG_BG_SCENE) != RG_EVERY_SCENE) any_scene_owned = true;
  }
  if (!any_scene_owned && brings_scenery == 0) return false;

  rg_screen_paint_owed_rebuild();
  var kept = shown_backgrounds.filter(function(entry) return background_field(entry, RG_BG_ON_ARRIVAL) == 0);
  if (kept.length == shown_backgrounds.length) return false;

  shown_backgrounds = kept;
  scenery_kept = 0;
  clear_to(backdrop);
  stamp_in_stack_order(-1);
  if (placed_fade_in_picture()) request_repaint(); /* a placed fade stays across the change */
  return true;
}

/* The state image is not written in Flash yet. */
static function rg_tiled_visit_state():Void { rg_state_refuse(); }
