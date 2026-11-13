/*
 * SCENERY DRAWN FROM TILES (Reference @bg_shown and the rest): backgrounds and status bars, the
 * maps they show and the cells the game changes, their scroll, turn, bends and boxes, the order a
 * stack of layers puts them in, and a scene's scenery coming down. A runtime feature
 * (backends/runtime_features.rb): joined into the runtime's script after rg_screen.js for a game
 * that declares a background, so it reads the screen's own state and painters as if it were
 * written there. rg_tiled.c says how, rule for rule; this is that file written again.
 */

const RG_EVERY_SCENE = -1;
const RG_NOT_A_BAR = -1;
const RG_MAX_BACKGROUNDS = 64;
const RG_BG_TILE_W = 0, RG_BG_TILE_H = 1, RG_BG_FIRST_MAP = 2, RG_BG_SHOWABLE_MAPS = 3, RG_BG_KEPT_BY = 4,
  RG_BG_NEVER_WRAPS = 5, RG_BG_TILES_START = 6, RG_BG_SCENE = 7, RG_BG_LEVEL = 8, RG_BG_ON_ARRIVAL = 9,
  RG_BG_STACK_PLACE = 10, RG_BG_SEE_THROUGH = 11, RG_BG_BENT = 12, RG_BG_FADE_PLACE = 13, RG_BG_TILES = 14,
  RG_BG_COLOR_STEPS = 15, RG_BG_IN_BLOCKS = 16, RG_BG_CAN_TURN = 17, RG_BG_PAINTED = 18, RG_BG_RUN_COLORS = 19,
  RG_BG_BAR_TOP = 20, RG_BG_ABOVE_ROW = 21, RG_BG_ALONE = 22, RG_BG_FIELDS = 23;
const RG_SHOWN_WITH_OTHERS = 0, RG_SHOWN_ALONE = 1, RG_SHOWN_WITHOUT_SPRITES = 2;
const RG_CELL_EMPTY = -1;
const RG_MAP_CELLS = 0, RG_MAP_COLS = 1, RG_MAP_ROWS = 2, RG_MAP_GRID_COLS = 3, RG_MAP_GRID_ROWS = 4, RG_MAP_FIELDS = 5;

function background_field(background, field) { return rg_game_backgrounds[background * RG_BG_FIELDS + field]; }

/* A background is painted onto a sheet of its own first when it is laid on the picture a part at a
 * time: inside a box it is held to, or in blocks (Reference#paint_scenery_in_blocks). While
 * +onto_sheet+ is set the background painters land there, as stored and with no blend, and every
 * row shows the map row +rows_tall+ rows above it at most, the top of its block. */
const NOTHING_ON_SHEET = -1;
const sheet = new Int32Array(RG_CELLS);
let onto_sheet = 0;
let rows_tall = 1;

/* The box a background is held to (Reference @bg_box), by the entry that keeps its name: whether it
 * is held to one, and its left, top, and the column and row just past it, kept to the screen
 * (Reference#screen_box). */
const boxes = Array.from({ length: RG_MAX_BACKGROUNDS }, () => ({ held: 0, left: 0, top: 0, right: 0, bottom: 0 }));

/* Scenery up, in the order it went up (Reference @bg_shown), one entry for every time a background
 * is put up. */
let shown_backgrounds = [];

/* What the game does to a background, kept at the entry that keeps it for the name. The cells
 * also hold whose map they are a copy of (declaration_up), and colors_told is one more than the
 * step of colors the game last named, nought for none. */
const cells_now = [], scrolls = [], colors_told = [], turns = [];
for (let i = 0; i < RG_MAX_BACKGROUNDS; i++) {
  cells_now.push({ which: 0, of: 0, cells: null });
  scrolls.push({ x: 0, y: 0 });
  colors_told.push(0);
  turns.push({ turned: 0, angle: 0, size: 0, pivot_x: 0, pivot_y: 0 });
}

/* The backgrounds put up this pass, shown from their top-left corner whatever their scroll
 * (Reference @bg_from_corner), whether there are any, and whether their pass has ended
 * (Reference @bg_corners_expired). */
const from_corner = new Array(RG_MAX_BACKGROUNDS).fill(0);
let any_from_corner = 0, corners_expired = 0;

/* --- scenery --- */

function keeper_of(background) { return background_field(background, RG_BG_KEPT_BY); }

/* Reference#background_up: the declaration of this background's name a line naming it means. */
function declaration_up(background) {
  const keeper = keeper_of(background);
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (keeper_of(bg) === keeper && showing(bg)) return bg;
  }
  return keeper;
}

/* Reference#background_swap: which set of its tiles this entry is drawn from now. */
function tile_set_now(background) {
  const step = colors_told[keeper_of(background)] - 1;
  return step >= 0 && step < background_field(background, RG_BG_COLOR_STEPS) ? step + 1 : 0;
}

/* Reference#scroll_shown: where a background's window sits on the display now. */
function scroll_shown(background) {
  const keeper = keeper_of(background);
  return from_corner[keeper] ? { x: 0, y: 0 } : scrolls[keeper];
}

/* Reference#forget_expired_corners. The interpreter builds a picture that is rebuilt whole every
 * frame, so a background that stops being shown from its corner is drawn from its scroll on the
 * next one without anything asking. Here a frame that moved nothing builds nothing, so the
 * corners going is itself a change to the picture, and asks for it. */
function forget_expired_corners() {
  if (!corners_expired) return;
  const were_shown_from_corners = any_from_corner;
  corners_expired = 0;
  from_corner.fill(0);
  any_from_corner = 0;
  if (were_shown_from_corners && rebuilt_whole()) request_repaint();
}

/* Reference#mark_from_corner */
function mark_from_corner(background) {
  forget_expired_corners();
  from_corner[keeper_of(background)] = 1;
  any_from_corner = 1;
}

/* Map number +which+ of a background's own maps, as where its entry starts in rg_game_maps. */
function map_entry(background, which) { return RG_MAP_FIELDS * (background_field(background, RG_BG_FIRST_MAP) + which); }

/* Reference#map_of: the map a background's cells hold now. */
function map_now(background) {
  const now = cells_now[keeper_of(background)];
  return now.cells ? map_entry(now.of, now.which) : map_entry(background, 0);
}

function map_cols(background) { return rg_game_maps[map_now(background) + RG_MAP_COLS]; }
function map_rows(background) { return rg_game_maps[map_now(background) + RG_MAP_ROWS]; }

function in_map(background, row, col) {
  return row >= 0 && row < map_rows(background) && col >= 0 && col < map_cols(background);
}

function cell_place(background, row, col) { return row * map_cols(background) + col; }

/* Reference#map_of: what a cell holds NOW. Below nought where it holds no tile. */
function map_cell(background, row, col) {
  if (!in_map(background, row, col)) return RG_CELL_EMPTY;
  const own = cells_now[keeper_of(background)].cells;
  if (own) return own[cell_place(background, row, col)];
  return rg_game_map_cells[rg_game_maps[map_now(background) + RG_MAP_CELLS] + cell_place(background, row, col)];
}

/* The name's cells become the run's own copy of map number +which+ of the maps of the declaration
 * up now. */
function copy_map(background, which) {
  const keeper = keeper_of(background), up = declaration_up(background);
  const map = map_entry(up, which);
  const start = rg_game_maps[map + RG_MAP_CELLS];
  const count = rg_game_maps[map + RG_MAP_COLS] * rg_game_maps[map + RG_MAP_ROWS];
  cells_now[keeper] = { which, of: up, cells: rg_game_map_cells.slice(start, start + count) };
}

function forget_own_cells(background) { cells_now[keeper_of(background)] = { which: 0, of: 0, cells: null }; }

/* The start of Reference#take_over. */
function rg_background_forget_cells(background) { forget_own_cells(background); }

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel). */
function tile_pixel(background, cell, tx, ty) {
  const painted = background_field(background, RG_BG_PAINTED);
  if (painted !== RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] !== RG_NOT_PAINTED) {
    const run = rg_game_painted_tiles[painted + 2 * cell];
    let which = rg_game_painted_tiles[painted + 2 * cell + 1];
    /* A big tile is kept as four squares, left to right and then down. */
    if (background_field(background, RG_BG_TILE_W) === 2 * RUN_TILE_SIDE) {
      which = which * 4 + Math.trunc(ty / RUN_TILE_SIDE) * 2 + Math.trunc(tx / RUN_TILE_SIDE);
      tx %= RUN_TILE_SIDE;
      ty %= RUN_TILE_SIDE;
    }
    const place = painted_places_at(places_of(run) + which * RUN_TILE_PIXELS + ty * RUN_TILE_SIDE + tx);
    const set = tile_set_now(background) * rg_game_picture_sizes[RG_SIZE_RUNS] + run;
    return rg_game_run_colors[background_field(background, RG_BG_RUN_COLORS) + set * PLACES_IN_RUN_COLORS + place];
  }
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const tile = tile_set_now(background) * background_field(background, RG_BG_TILES) + cell;
  return rg_game_tile_pixels[background_field(background, RG_BG_TILES_START) + tile * tile_w * tile_h + ty * tile_w + tx];
}



/* Reference#grid_repeats: how many times the grid is seen along one side of the screen. */
function grid_repeats(background, grid_cells, screen_side) {
  if (background_field(background, RG_BG_NEVER_WRAPS) || background_field(background, RG_BG_TILE_W) !== 8 ||
      background_field(background, RG_BG_TILE_H) !== 8) return 1;
  return Math.ceil(screen_side / (grid_cells * 8));
}

/* The map onto the picture with its corner at (left, top), cell by cell. */
function stamp_map_at(background, left, top) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const rows = map_rows(background), cols = map_cols(background);
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (let ty = 0; ty < tile_h; ty++) {
        for (let tx = 0; tx < tile_w; tx++) {
          const color = tile_pixel(background, cell, tx, ty);
          if (color !== RG_SEE_THROUGH) set_pixel(left + col * tile_w + tx, top + row * tile_h + ty, color);
        }
      }
    }
  }
}

/* Reference#stamp_background */
function rg_background_stamp(background) {
  /* Reference#stamp_background: a status bar is painted from its own top as the view is built, and
   * a background held above a row stops at it, and one under a background shown alone starts there. */
  if (background_field(background, RG_BG_BAR_TOP) !== RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) !== RG_NOT_A_BAR || boxes[keeper_of(background)].held ||
      row_held_alone_by_another(background) !== RG_NOT_A_BAR) {
    request_repaint();
    return;
  }
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  const map = map_now(background);
  const grid_cols = rg_game_maps[map + RG_MAP_GRID_COLS], grid_rows = rg_game_maps[map + RG_MAP_GRID_ROWS];
  const across = grid_repeats(background, grid_cols, RG_SCREEN_WIDTH);
  const down = grid_repeats(background, grid_rows, RG_SCREEN_HEIGHT);
  for (let round_down = 0; round_down < down; round_down++) {
    for (let round_across = 0; round_across < across; round_across++) {
      stamp_map_at(background, round_across * grid_cols * 8, round_down * grid_rows * 8);
    }
  }
  mix_nothing();
}

function stack_place(background) { return background_field(background, RG_BG_STACK_PLACE); }

/* Reference#behind?: only when both named a layer. */
function behind(a, b) {
  return stack_place(a) !== RG_NO_LAYER && stack_place(b) !== RG_NO_LAYER && stack_place(a) < stack_place(b);
}

function remember_put_up(background) { shown_backgrounds.push(background); }

function in_order_asked(entry, over) { return over < 0 || behind(over, entry); }

/* Where the LAST entry for +background+ lands once the entries asked for are put in the order the
 * stack asks for (IR::Stacking.order_by_stack), or -1 when it has no entry. */
function last_place_in_stack_order(background, over) {
  const place = stack_place(background);
  let at = -1, last = -1, further_back = 0, in_its_layer = 0, in_its_layer_by_last = 0;
  for (const entry of shown_backgrounds) {
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) !== RG_NO_LAYER && stack_place(entry) < place) further_back++;
    if (stack_place(entry) !== RG_NO_LAYER && stack_place(entry) === place) in_its_layer++;
    if (entry === background) {
      last = at;
      in_its_layer_by_last = in_its_layer;
    }
  }
  if (last < 0 || place === RG_NO_LAYER) return last;

  const nth = further_back + in_its_layer_by_last - 1;
  let named = -1;
  at = -1;
  for (const entry of shown_backgrounds) {
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) !== RG_NO_LAYER && ++named === nth) return at;
  }
  return -1;
}

/* Reference#in_stack_order over the scenery that is up, each stamped once in that order. */
function stamp_in_stack_order(over) {
  if (over >= 0 && stack_place(over) === RG_NO_LAYER) return;
  const backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  const lands = [];
  for (let bg = 0; bg < backgrounds; bg++) lands.push(last_place_in_stack_order(bg, over));
  for (;;) {
    let next = -1;
    for (let bg = 0; bg < backgrounds; bg++) {
      if (lands[bg] >= 0 && (next < 0 || lands[bg] < lands[next])) next = bg;
    }
    if (next < 0) return;
    rg_background_stamp(next);
    lands[next] = -1;
  }
}

/* Reference#put_up_background */
function rg_background_put_up(background) {
  /* A change still waiting to this background's name was made to cells put up again now; the
   * changes to every other background are kept, in the order made. */
  const keeper = keeper_of(background);
  held_tiles = held_tiles.filter((change) => keeper_of(change.background) !== keeper);
  if (background_field(background, RG_BG_ON_ARRIVAL)) {
    forget_own_cells(background);
    boxes[keeper_of(background)].held = 0; /* its scene puts it up showing everywhere */
  }
  remember_put_up(background);
  mark_from_corner(background);
  scenery_kept = 0;
  if (turns[keeper_of(background)].turned || background_field(background, RG_BG_BAR_TOP) !== RG_NOT_A_BAR ||
      background_field(background, RG_BG_ABOVE_ROW) !== RG_NOT_A_BAR || bar_showing() >= 0 ||
      boxes[keeper_of(background)].held || placed_fade_in_picture()) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
  stamp_in_stack_order(background);
}

/* Reference#exec_affine_background */
function rg_background_turn(background, angle, size, pivot_x, pivot_y) {
  turns[keeper_of(background)] = { turned: 1, angle: floor_mod(angle, 360), size, pivot_x, pivot_y };
  request_repaint();
}

/* Reference#showing_scenery */
function showing(background) {
  const scene = background_field(background, RG_BG_SCENE);
  return scene === RG_EVERY_SCENE || scene === current_scene;
}


/* Reference#exec_scroll_background. The interpreter builds the view again every time; this builds
 * it again only when the scroll the picture shows is not the one it was built with, so a frame
 * that sets the same scroll again costs nothing. What the picture shows is what scroll_shown
 * answers, which for a background put up this pass is its corner, so a scroll set over a corner
 * is a change even where the number written is the one already stored. */

function rg_background_scroll(background, x, y) {
  const before = scroll_shown(background);
  scrolls[keeper_of(background)] = { x, y };
  if (!placing_at_pass_end) from_corner[keeper_of(background)] = 0;
  const after = scroll_shown(background);
  if (after.x !== before.x || after.y !== before.y) request_repaint();
  else skip_repaint();
}

/* Where each status bar was last placed, by the entry that keeps its name, and whether it has
 * been (Reference @bar_top). */
const bar_tops = new Array(RG_MAX_BACKGROUNDS).fill(0);
const bar_placed = new Array(RG_MAX_BACKGROUNDS).fill(0);

/* Reference#exec_place_bar */
function rg_place_bar(background, top) {
  bar_tops[keeper_of(background)] = clamp_number(top, 0, RG_SCREEN_HEIGHT);
  bar_placed[keeper_of(background)] = 1;
  if (!placing_at_pass_end) from_corner[keeper_of(background)] = 0;
  request_repaint();
}

/* Reference#exec_box_background and #screen_box: a box with nothing on the screen is an empty one
 * at the corner. */
function rg_background_box(background, x, y, width, height, held) {
  const box = boxes[keeper_of(background)];
  if (held === 0) {
    box.held = 0;
  } else {
    Object.assign(box, { held: 1, left: 0, top: 0, right: 0, bottom: 0 });
    if (width > 0 && height > 0) {
      const left = clamp_number(x, 0, RG_SCREEN_WIDTH), right = clamp_number(x + width, 0, RG_SCREEN_WIDTH);
      const top = clamp_number(y, 0, RG_SCREEN_HEIGHT), bottom = clamp_number(y + height, 0, RG_SCREEN_HEIGHT);
      if (right > left && bottom > top) Object.assign(box, { left, top, right, bottom });
    }
  }
  request_repaint();
}

/* Which status bars hide the sprites from their top down, by the same entry (Reference @bar_covers). */
const bar_covers = new Array(RG_MAX_BACKGROUNDS).fill(0);

function rg_bar_covers(background, covers) {
  bar_covers[keeper_of(background)] = covers !== 0 ? 1 : 0;
  request_repaint();
}

/* Reference#bar_top_shown */
function bar_top_shown(bar) {
  const declared = clamp_number(background_field(bar, RG_BG_BAR_TOP), 0, RG_SCREEN_HEIGHT);
  const keeper = keeper_of(bar);
  return from_corner[keeper] || !bar_placed[keeper] ? declared : bar_tops[keeper];
}

/* Reference#bar_showing: the status bar on screen, or -1. */
function bar_showing() {
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg) && background_field(bg, RG_BG_BAR_TOP) !== RG_NOT_A_BAR) return bg;
  }
  return -1;
}

/* Reference#scenery_rows */
function scenery_rows() {
  const bar = bar_showing();
  return bar < 0 ? RG_SCREEN_HEIGHT : bar_top_shown(bar);
}

/* Reference#rows_shown_of */
function rows_shown_of(background) {
  const above = background_field(background, RG_BG_ABOVE_ROW);
  return above === RG_NOT_A_BAR ? scenery_rows() : Math.min(scenery_rows(), above);
}

/* Reference#row_held_alone_by_another: the row of a background up and shown alone above it,
 * where +background+ is another, or RG_NOT_A_BAR. */
function row_held_alone_by_another(background) {
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (bg !== background && showing(bg) && background_field(bg, RG_BG_ALONE)) return background_field(bg, RG_BG_ABOVE_ROW);
  return RG_NOT_A_BAR;
}

/* Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. */
function rg_background_set_tile(background, col, row, tile) {
  /* A tile only another scene's declaration of the name has changes nothing here. */
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (!cells_now[keeper_of(background)].cells) copy_map(background, 0);
  if (!in_map(background, row, col)) return;
  const cells = cells_now[keeper_of(background)].cells;
  const at = cell_place(background, row, col);
  if (cells[at] === tile) return;
  cells[at] = tile;
  request_repaint();
}

/* The cell changes of backgrounds declared `held: true`, waiting for rg_show_held_tiles
 * (Reference's @held_tiles), in the order the game made them. */
let held_tiles = [];

/* Reference#exec_set_tile, held: the change waits, its cell worked out now. With +most+ waiting,
 * everything waiting goes in first. */
function rg_background_hold_tile(background, col, row, tile, most) {
  if (tile >= background_field(declaration_up(background), RG_BG_TILES)) return;
  if (held_tiles.length >= most) rg_show_held_tiles();
  held_tiles.push({ background, col, row, tile });
}

/* Reference#exec_show_held_tiles */
function rg_show_held_tiles() {
  const waiting = held_tiles;
  held_tiles = [];
  for (const change of waiting) rg_background_set_tile(change.background, change.col, change.row, change.tile);
}

function rg_background_show_map(background, which) {
  if (which < 0 || which >= background_field(declaration_up(background), RG_BG_SHOWABLE_MAPS)) return;
  copy_map(background, which);
  request_repaint();
}

function rg_background_draw_with(background, which) {
  colors_told[keeper_of(background)] = which < 0 ? 0 : which + 1;
  request_repaint();
}

/* rg_tiled.c's rg_background_follow: the tiles a background draws from one of several lists it
 * follows are copied from set number +set+ of its tiles over the ones the picture is drawn from. */
function rg_background_follow(rules, set) {
  const background = rules[1], count = rules[2];
  const tile_size = background_field(background, RG_BG_TILE_W) * background_field(background, RG_BG_TILE_H);
  const start = background_field(background, RG_BG_TILES_START);
  const set_size = background_field(background, RG_BG_TILES) * tile_size;
  let changed = false;
  for (let i = 0; i < count; i++) {
    const to = start + rules[3 + i] * tile_size, from = to + set * set_size;
    for (let at = 0; at < tile_size; at++) {
      if (rg_game_tile_pixels[to + at] === rg_game_tile_pixels[from + at]) continue;
      rg_game_tile_pixels[to + at] = rg_game_tile_pixels[from + at];
      changed = true;
    }
  }
  if (changed) request_repaint();
}

/* Framebuffer#paint_row, a cell at a time */
function lay_scenery(px, py, color) {
  const at = py * RG_SCREEN_WIDTH + px;
  pixels[at] = into_cell(color, pixels[at], pixels, at);
  if (sprites_seen_through()) picture_without_sprites[at] = pixels[at];
}

function paint_map_pixel(background, mx, my, px, py) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const cell = map_cell(background, Math.trunc(my / tile_h), Math.trunc(mx / tile_w));
  if (cell < 0) return;
  const color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
  if (color === RG_SEE_THROUGH) return;
  if (onto_sheet) sheet[py * RG_SCREEN_WIDTH + px] = color;
  else lay_scenery(px, py, color);
}

function row_drawn_from(py) { return py - (py % rows_tall); }

const asked_bend = { background: NOBODY_ASKED, py: 0, offset: 0 };

function rg_bend_asked(background) { return background === asked_bend.background ? 1 : 0; }
function rg_bend_line() { return asked_bend.py; }
function rg_bend_answer(offset) { asked_bend.offset = offset; }

const bend_lines = [], bend_lines_kept = [];
for (let i = 0; i < RG_MAX_BACKGROUNDS; i++) {
  bend_lines.push(new Int32Array(RG_SCREEN_HEIGHT));
  bend_lines_kept.push(0);
}

/* Reference#run_bend_for_row */
function run_bend_for_line(keeper, py) {
  asked_bend.background = keeper;
  asked_bend.py = py;
  rg_game_bend_offsets();
  asked_bend.background = NOBODY_ASKED;
  return asked_bend.offset;
}

function rg_bend_work_out(background, first_line, past_line) {
  const keeper = keeper_of(background);
  for (let py = first_line; py < past_line; py++) bend_lines[keeper][py] = run_bend_for_line(keeper, py);
  bend_lines_kept[keeper] = 1;
}

/* Reference#work_out_bends */
function rg_screen_work_out_bends() {
  rg_game_work_out_bends();
  if (frames_begun) request_repaint();
}

/* Reference#bend_offset_at */
function bend_at(background, py) {
  if (!background_field(background, RG_BG_BENT)) return 0;
  const keeper = keeper_of(background);
  if (bend_lines_kept[keeper]) return bend_lines[keeper][py];
  return frames_begun ? 0 : run_bend_for_line(keeper, py);
}

/* Reference#paint_streamed_background_window */
function paint_window_without_wrapping(background) {
  const map_h = map_rows(background) * background_field(background, RG_BG_TILE_H);
  const scroll = scroll_shown(background);
  for (let py = 0, rows = rows_shown_of(background); py < rows; py++) {
    const my = scroll.y + row_drawn_from(py);
    if (my < 0 || my >= map_h) continue;
    const off_x = scroll.x + bend_at(background, py);
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const mx = off_x + px;
      if (mx >= 0) paint_map_pixel(background, mx, my, px, py);
    }
  }
}

/* Reference#paint_background_window, for a background never turned */
function paint_window(background) {
  if (background_field(background, RG_BG_NEVER_WRAPS)) {
    paint_window_without_wrapping(background);
    return;
  }
  const map = map_now(background);
  const map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * background_field(background, RG_BG_TILE_W);
  const map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * background_field(background, RG_BG_TILE_H);
  if (map_w === 0 || map_h === 0) return;
  const scroll = scroll_shown(background);
  const off_y = floor_mod(scroll.y, map_h);
  for (let py = 0, rows = rows_shown_of(background); py < rows; py++) {
    const off_x = floor_mod(scroll.x + bend_at(background, py), map_w);
    const my = (off_y + row_drawn_from(py)) % map_h;
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) paint_map_pixel(background, (off_x + px) % map_w, my, px, py);
  }
}

/* Reference#paint_affine_background_window */
function paint_turned_window(background) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const map = map_now(background);
  const map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * tile_w;
  const map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * tile_h;
  if (map_w === 0 || map_h === 0) return;
  const turn = turns[keeper_of(background)];
  // A turned layer is placed by its turn, which putting it up leaves as it is.
  const scroll = scrolls[keeper_of(background)];
  const pivot_x = turn.pivot_x, pivot_y = turn.pivot_y, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(turn.angle, turn.size);
  for (let py = 0, rows = scenery_rows(); py < rows; py++) {
    const dy = row_drawn_from(py) - pivot_y;
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const dx = px - pivot_x;
      const mx = floor_mod(scroll.x + pivot_x + floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      const my = floor_mod(scroll.y + pivot_y + floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
      const cell = map_cell(background, Math.trunc(my / tile_h), Math.trunc(mx / tile_w));
      if (cell < 0) continue;
      const color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color === RG_SEE_THROUGH) continue;
      if (onto_sheet) sheet[py * RG_SCREEN_WIDTH + px] = color;
      else set_pixel(px, py, color);
    }
  }
}

function paint_background(background) {
  if (turns[keeper_of(background)].turned) paint_turned_window(background);
  else paint_window(background);
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
 * to the box as it is laid (+box+, or null).
 *
 * Reference#block_width_across: a background that can turn is left one pixel wide at a size of
 * two, so its rows double and its columns do not. That is the emulator's, kept because the
 * console's picture is checked against it. */
function paint_scenery_in_blocks(background, block, box) {
  sheet.fill(NOTHING_ON_SHEET);
  onto_sheet = 1;
  rows_tall = block;
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  const wide = background_field(background, RG_BG_CAN_TURN) && block === 2 ? 1 : block;
  for (let py = 0, rows = scenery_rows(); py < rows; py++) {
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      if (box && (px < box.left || px >= box.right || py < box.top || py >= box.bottom)) continue;
      const color = sheet[py * RG_SCREEN_WIDTH + px - (px % wide)];
      if (color !== NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_scenery_in_box: a background held to a box goes onto the sheet as it would onto
 * the picture, and only its pixels inside the box are laid on the picture. */
function paint_scenery_in_box(background, box) {
  sheet.fill(NOTHING_ON_SHEET);
  onto_sheet = 1;
  paint_background(background);
  onto_sheet = 0;
  for (let py = box.top; py < box.bottom; py++) {
    for (let px = box.left; px < box.right; px++) {
      const color = sheet[py * RG_SCREEN_WIDTH + px];
      if (color !== NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_status_bar_rows: a row in a block that starts above the bar reads the bar's map
 * above its first row, where its grid comes round. */
function paint_status_bar_rows(bar) {
  const top = bar_top_shown(bar);
  const grid_h = rg_game_maps[map_now(bar) + RG_MAP_GRID_ROWS] * background_field(bar, RG_BG_TILE_H);
  for (let py = top; py < RG_SCREEN_HEIGHT; py++) {
    let my = row_drawn_from(py) - top;
    if (my < 0) {
      if (grid_h === 0) continue;
      my = floor_mod(my, grid_h);
    }
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) paint_map_pixel(bar, px, my, px, py);
  }
}

/* Reference#paint_status_bar */
function paint_status_bar(bar) {
  const block = rg_hook_block_size();
  if (block === 1 || !background_field(bar, RG_BG_IN_BLOCKS)) {
    paint_status_bar_rows(bar);
    return;
  }
  sheet.fill(NOTHING_ON_SHEET);
  onto_sheet = 1;
  rows_tall = block;
  paint_status_bar_rows(bar);
  onto_sheet = 0;
  rows_tall = 1;
  for (let py = bar_top_shown(bar); py < RG_SCREEN_HEIGHT; py++) {
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const color = sheet[py * RG_SCREEN_WIDTH + px - (px % block)];
      if (color !== NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

/* Reference#paint_scenery: a background held to a box with nothing in it paints nothing; one the
 * game has not left as drawn is painted in blocks while the blocks are bigger than a pixel. Under a
 * background shown alone above its row, it is held to the rows from there down as if to a box
 * (Reference#box_shown_of). */
function paint_scenery(background) {
  let shown = boxes[keeper_of(background)];
  const alone = row_held_alone_by_another(background);
  if (alone !== RG_NOT_A_BAR) {
    shown = shown.held ? { ...shown } : { held: 1, left: 0, top: 0, right: RG_SCREEN_WIDTH, bottom: RG_SCREEN_HEIGHT };
    if (shown.top < alone) shown.top = alone;
  }
  const box = shown.held ? shown : null;
  if (box && (box.right <= box.left || box.bottom <= box.top)) return;
  const block = rg_hook_block_size();
  if (block > 1 && background_field(background, RG_BG_IN_BLOCKS)) paint_scenery_in_blocks(background, block, box);
  else if (box) paint_scenery_in_box(background, box);
  else paint_background(background);
}

/* Reference#set_blend_for, for scenery: what is painted next is mixed as the layer the background
 * is in, and faded unless a placed fade leaves it as drawn. */
function blend_as_background(background) {
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  fade_unless_left_as_drawn(background_field(background, RG_BG_FADE_PLACE));
}

/* --- the hooks it takes --- */

/* Reference#exec_screen: a screen of another kind wipes the scenery, and arriving on one drawn
 * from tiles puts up again what every such screen shows, as declared (#put_up_always_up). */
function rg_tiled_screen_crossed(new_kind) {
  shown_backgrounds = [];
  if (new_kind === RG_BITMAP) return;
  for (let i = 0; i < rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]; i++) {
    forget_own_cells(rg_game_always_up[i]);
    rg_background_put_up(rg_game_always_up[i]);
  }
}

/* The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its
 * picture is painted (Reference#forget_expired_corners). */
function rg_tiled_frame_ended() {
  if (any_from_corner) corners_expired = 1;
}

function rg_tiled_repaint_requested() { forget_expired_corners(); }
function rg_tiled_rebuild_checked() { forget_expired_corners(); }

/* The status bar's state while the view is rebuilt, from rg_tiled_repaint_began to
 * rg_tiled_repaint_ending: the bar on screen, or -1. */
let bar_in_rebuild = -1;

/* A status bar is painted first: no background is painted under it, so it is in front of all of
 * them and every sprite is painted over it. */
function rg_tiled_repaint_began() {
  bar_in_rebuild = bar_showing();
  if (bar_in_rebuild < 0) return;
  blend_as_background(bar_in_rebuild);
  paint_status_bar(bar_in_rebuild);
}

function rg_tiled_paint_level(level) {
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (!showing(bg) || background_field(bg, RG_BG_LEVEL) !== level) continue;
    blend_as_background(bg);
    paint_scenery(bg);
  }
}

/* Reference#paint_held_over_sprites: a background shown alone without sprites painted again over
 * its rows, from the backdrop up. */
function paint_held_over_sprites(held) {
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  fill_cells(0, 0, RG_SCREEN_WIDTH, rows_shown_of(held), backdrop);
  blend_as_background(held);
  paint_scenery(held);
}

/* Reference#paint_bar_over_sprites */
function paint_bar_over_sprites(bar) {
  const top = bar_top_shown(bar);
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  fill_cells(0, top, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT - top, backdrop);
  blend_as_background(bar);
  paint_status_bar(bar);
}

/* The end of Reference#repaint_view */
function rg_tiled_repaint_ending() {
  const bar = bar_in_rebuild;
  bar_in_rebuild = -1;
  if (bar >= 0 && bar_covers[keeper_of(bar)]) paint_bar_over_sprites(bar);
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg) && background_field(bg, RG_BG_ALONE) === RG_SHOWN_WITHOUT_SPRITES) {
      paint_held_over_sprites(bg);
      return;
    }
  }
}

/* Reference#scene_framebuffer: every background showing, stamped. */
function rg_tiled_stamp_scenery() {
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg)) rg_background_stamp(bg);
  }
}

function rg_tiled_scenery_up() { return shown_backgrounds.length > 0; }

/* Reference#layer_has_anything?, for scenery: a background showing now in that layer. */
function rg_tiled_layer_holds_scenery(layer) {
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg) && background_field(bg, RG_BG_SEE_THROUGH) === layer) return true;
  }
  return false;
}

/* Reference#take_down_scenery: the last scene's own scenery comes down, and the picture goes back
 * to the scenery every screen shows. Answers whether any came down. */
function rg_tiled_scene_take_down(brings_scenery) {
  let any_scene_owned = false;
  for (const entry of shown_backgrounds) {
    if (background_field(entry, RG_BG_SCENE) !== RG_EVERY_SCENE) any_scene_owned = true;
  }
  if (!any_scene_owned && !brings_scenery) return false;

  rg_screen_paint_owed_rebuild();
  const kept = shown_backgrounds.filter((entry) => !background_field(entry, RG_BG_ON_ARRIVAL));
  if (kept.length === shown_backgrounds.length) return false;

  shown_backgrounds = kept;
  scenery_kept = 0;
  clear_to(backdrop);
  stamp_in_stack_order(-1);
  if (placed_fade_in_picture()) request_repaint(); /* a placed fade stays across the change */
  return true;
}

/* --- the state image --- */

/* How many numbers "tiled.backgrounds" holds for each background (rg_tiled.c's
 * BACKGROUND_STATE_NUMBERS), and where in them its own cells and its bends are marked. */
const STATE_HAS_OWN_CELLS = 0, STATE_MAP_WHICH = 1, STATE_MAP_OF = 2, STATE_BENDS_KEPT = 20, BACKGROUND_STATE_NUMBERS = 21;
const HELD_TILE_NUMBERS = 4; /* background, column, row, tile */
const MOST_SCENERY_PUT_UP = 1 << 28; /* rg_tiled.c's remember_put_up's limit */
const HELD_TILES_ROOM = 1024; /* rg_tiled.h's RG_HELD_TILES_ROOM */

/* How many cells a copy of map +which+ of entry +of+ holds. */
function map_copy_cell_count(of, which) {
  const map = map_entry(of, which);
  return rg_game_maps[map + RG_MAP_COLS] * rg_game_maps[map + RG_MAP_ROWS];
}

/* A background's numbers, as "tiled.backgrounds" holds them (rg_tiled.c's background_state_numbers). */
function background_state_numbers(background) {
  const cells = cells_now[background], box = boxes[background], turn = turns[background];
  const held = box.held ? 1 : 0;
  return [
    cells.cells ? 1 : 0, cells.which, cells.of, scrolls[background].x, scrolls[background].y,
    from_corner[background] ? 1 : 0, colors_told[background],
    held, held ? box.left : 0, held ? box.top : 0, held ? box.right : 0, held ? box.bottom : 0,
    turn.turned ? 1 : 0, turn.angle, turn.size, turn.pivot_x, turn.pivot_y,
    bar_tops[background], bar_placed[background] ? 1 : 0, bar_covers[background] ? 1 : 0, bend_lines_kept[background] ? 1 : 0,
  ];
}

/* A background's numbers read from the image, all but its cells and its bends. */
function read_background_state(background, n) {
  const which = n[STATE_MAP_WHICH], of = n[STATE_MAP_OF];
  if (n[STATE_HAS_OWN_CELLS] && (of < 0 || of >= rg_game_picture_sizes[RG_SIZE_BACKGROUNDS] || which < 0 ||
                                 (which > 0 && which >= background_field(of, RG_BG_SHOWABLE_MAPS)))) {
    rg_state_refuse_damaged("a background holds a map it does not have");
  }
  cells_now[background] = { which, of, cells: null };
  scrolls[background] = { x: n[3], y: n[4] };
  from_corner[background] = n[5] !== 0 ? 1 : 0;
  colors_told[background] = n[6];
  boxes[background] = { held: n[7] !== 0 ? 1 : 0, left: n[8], top: n[9], right: n[10], bottom: n[11] };
  turns[background] = { turned: n[12] !== 0 ? 1 : 0, angle: n[13], size: n[14], pivot_x: n[15], pivot_y: n[16] };
  bar_tops[background] = n[17];
  bar_placed[background] = n[18] !== 0 ? 1 : 0;
  bar_covers[background] = n[19] !== 0 ? 1 : 0;
  bend_lines_kept[background] = n[STATE_BENDS_KEPT] !== 0 ? 1 : 0;
}

/* rg_hook_visit_state (rg_tiled.c's rg_tiled_visit_state): the scenery up and the changes waiting,
 * then what each background's name keeps, the cells of its own copy, and the lines of its bends. */
function rg_tiled_visit_state() {
  const reading = rg_state_reading();
  const backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  const counts = [any_from_corner ? 1 : 0, corners_expired ? 1 : 0, shown_backgrounds.length, held_tiles.length];
  rg_state_numbers("tiled", counts);
  if (counts[2] < 0 || counts[2] >= MOST_SCENERY_PUT_UP || counts[3] < 0 || counts[3] > HELD_TILES_ROOM) {
    rg_state_refuse_damaged("the scenery holds more than it can");
  }
  any_from_corner = counts[0] !== 0 ? 1 : 0;
  corners_expired = counts[1] !== 0 ? 1 : 0;

  const shown = reading ? new Array(counts[2]).fill(0) : [...shown_backgrounds];
  rg_state_numbers("tiled.shown", shown);
  if (!shown.every((bg) => bg >= 0 && bg < backgrounds)) {
    rg_state_refuse_damaged("the scenery up names a background the game does not have");
  }
  shown_backgrounds = shown;

  const held = reading ? new Array(HELD_TILE_NUMBERS * counts[3]).fill(0) :
    held_tiles.flatMap((change) => [change.background, change.col, change.row, change.tile]);
  rg_state_numbers("tiled.held", held);
  held_tiles = [];
  for (let i = 0; i < held.length; i += HELD_TILE_NUMBERS) {
    if (held[i] < 0 || held[i] >= backgrounds) rg_state_refuse_damaged("a tile change waits for a background the game does not have");
    held_tiles.push({ background: held[i], col: held[i + 1], row: held[i + 2], tile: held[i + 3] });
  }

  const per_background = reading ? new Array(backgrounds * BACKGROUND_STATE_NUMBERS).fill(0) :
    Array.from({ length: backgrounds }, (_, bg) => background_state_numbers(bg)).flat();
  rg_state_numbers("tiled.backgrounds", per_background);
  const numbers_of = (bg) => per_background.slice(bg * BACKGROUND_STATE_NUMBERS, (bg + 1) * BACKGROUND_STATE_NUMBERS);
  if (reading) for (let bg = 0; bg < backgrounds; bg++) read_background_state(bg, numbers_of(bg));

  const owners = [], bent_backgrounds = [];
  for (let bg = 0; bg < backgrounds; bg++) {
    if (numbers_of(bg)[STATE_HAS_OWN_CELLS]) owners.push(bg);
    if (numbers_of(bg)[STATE_BENDS_KEPT]) bent_backgrounds.push(bg);
  }
  const sizes = owners.map((bg) => map_copy_cell_count(numbers_of(bg)[STATE_MAP_OF], numbers_of(bg)[STATE_MAP_WHICH]));
  const cells = reading ? new Array(sizes.reduce((sum, size) => sum + size, 0)).fill(0) :
    owners.flatMap((bg) => Array.from(cells_now[bg].cells));
  rg_state_numbers("tiled.cells", cells);
  if (reading) {
    let at = 0;
    owners.forEach((bg, i) => {
      cells_now[bg].cells = Int16Array.from(cells.slice(at, at + sizes[i]));
      at += sizes[i];
    });
  }

  const lines = reading ? new Array(bent_backgrounds.length * RG_SCREEN_HEIGHT).fill(0) :
    bent_backgrounds.flatMap((bg) => Array.from(bend_lines[bg]));
  rg_state_numbers("tiled.bends", lines);
  if (reading) bent_backgrounds.forEach((bg, i) => bend_lines[bg].set(lines.slice(i * RG_SCREEN_HEIGHT, (i + 1) * RG_SCREEN_HEIGHT)));
}

