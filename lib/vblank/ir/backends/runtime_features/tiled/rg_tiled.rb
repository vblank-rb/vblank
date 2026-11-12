# frozen_string_literal: true

# SCENERY DRAWN FROM TILES (Reference @bg_shown and the rest): backgrounds and status bars, the
# maps they show and the cells the game changes, their scroll, turn, bends and boxes, the order a
# stack of layers puts them in, and a scene's scenery coming down. A runtime feature
# (backends/runtime_features.rb), joined into the runtime's class after rg_screen.rb for a game
# that declares a background, so it reads the screen's own state and painters as if it were written
# there. rg_tiled.c says how, rule for rule; this is that file written again.

RG_EVERY_SCENE = -1
RG_NEVER_ARRIVES = -2
RG_NOT_A_BAR = -1
RG_NOT_PAINTED = -1
RG_CELL_EMPTY = -1
RG_MAX_BACKGROUNDS = 64

# Each background is RG_BG_FIELDS numbers in @rg_game_backgrounds, in the order the stack draws
# them: the size of its tiles; its first map among @rg_game_maps and how many it can be handed
# while the game runs; the entry that keeps what the game does to its name (two scenes can each
# declare a background by one name); whether it never comes round at its map's edge; where its
# tiles start in @rg_game_tile_pixels; its scene (RG_EVERY_SCENE for scenery every screen shows,
# RG_NEVER_ARRIVES for a scene nothing hands the screen to), its depth, whether it comes up with
# its scene, and how far forward the layer it named is (RG_NO_LAYER for none); its see-through
# layer or RG_SOLID; whether it is bent; how far forward a placed fade's layer can be and still
# leave it as drawn; how many tiles it has and how many steps of colors it can be told; whether
# it goes into blocks and whether it can turn; and where its painted tiles and their colors are,
# or RG_NOT_PAINTED.
RG_BG_TILE_W = 0
RG_BG_TILE_H = 1
RG_BG_FIRST_MAP = 2
RG_BG_SHOWABLE_MAPS = 3
RG_BG_KEPT_BY = 4
RG_BG_NEVER_WRAPS = 5
RG_BG_TILES_START = 6
RG_BG_SCENE = 7
RG_BG_LEVEL = 8
RG_BG_ON_ARRIVAL = 9
RG_BG_STACK_PLACE = 10
RG_BG_SEE_THROUGH = 11
RG_BG_BENT = 12
RG_BG_FADE_PLACE = 13
RG_BG_TILES = 14
RG_BG_COLOR_STEPS = 15
RG_BG_IN_BLOCKS = 16
RG_BG_CAN_TURN = 17
RG_BG_PAINTED = 18
RG_BG_RUN_COLORS = 19
RG_BG_BAR_TOP = 20
RG_BG_ABOVE_ROW = 21
RG_BG_FIELDS = 22

# Each map is RG_MAP_FIELDS numbers in @rg_game_maps.
RG_MAP_CELLS = 0
RG_MAP_COLS = 1
RG_MAP_ROWS = 2
RG_MAP_GRID_COLS = 3
RG_MAP_GRID_ROWS = 4
RG_MAP_FIELDS = 5

RG_NOTHING_ON_SHEET = -1

# How a background is turned, once it has been turned or resized at all (Reference @bg_affine).
RgTurn = Struct.new(:turned, :angle, :size, :pivot_x, :pivot_y)

def rg_background_field(background, field) = @rg_game_backgrounds[(background * RG_BG_FIELDS) + field]

# --- scenery ---

# The entry that keeps what the game does to this background's name (RG_BG_KEPT_BY): itself,
# unless another scene declared a background by the same name after it.
def rg_keeper_of(background) = rg_background_field(background, RG_BG_KEPT_BY)

# Reference#background_up: the declaration of this background's name a line naming it means: the
# one on the screen up now, where two scenes each declare one by the name, or the keeping entry
# where none of them is up.
def rg_declaration_up(background)
  keeper = rg_keeper_of(background)
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times do |bg|
    return bg if rg_keeper_of(bg) == keeper && rg_showing?(bg)
  end
  keeper
end

# Reference#background_swap: which set of its tiles this entry is drawn from now. 0 for the colors
# they were drawn in, which is also what a number naming none of its steps means, or one more than
# the step the game last named.
def rg_tile_set_now(background)
  step = @rg_colors_told[rg_keeper_of(background)] - 1
  step >= 0 && step < rg_background_field(background, RG_BG_COLOR_STEPS) ? step + 1 : 0
end

# Reference#scroll_shown: where a background's window sits on the display now.
def rg_scroll_shown(background)
  keeper = rg_keeper_of(background)
  @rg_from_corner[keeper] ? [0, 0] : @rg_scrolls[keeper]
end

# Reference#forget_expired_corners. The interpreter builds a picture that is rebuilt whole every
# frame, so a background that stops being shown from its corner is drawn from its scroll on the
# next one without anything asking. Here a frame that moved nothing builds nothing, so the corners
# going is itself a change to the picture, and asks for it.
def rg_forget_expired_corners
  return unless @rg_corners_expired

  were_shown_from_corners = @rg_any_from_corner
  @rg_corners_expired = false
  @rg_from_corner.fill(false)
  @rg_any_from_corner = false
  rg_request_repaint if were_shown_from_corners && rg_rebuilt_whole?
end

# Reference#mark_from_corner
def rg_mark_from_corner(background)
  rg_forget_expired_corners
  @rg_from_corner[rg_keeper_of(background)] = true
  @rg_any_from_corner = true
end

# Where map number +which+ of a background's own maps starts in @rg_game_maps.
def rg_map_entry(background, which) = RG_MAP_FIELDS * (rg_background_field(background, RG_BG_FIRST_MAP) + which)

# Reference#map_of: where the map a background's cells hold now starts in @rg_game_maps. That is
# the run's own copy for the name where there is one, which is a copy of one of the maps of the
# entry it was made from; and the first of this background's own maps where there is none.
def rg_map_now(background)
  which, cells, of = @rg_cells_now[rg_keeper_of(background)]
  cells ? rg_map_entry(of, which) : rg_map_entry(background, 0)
end

def rg_map_cols(background) = @rg_game_maps[rg_map_now(background) + RG_MAP_COLS]
def rg_map_rows(background) = @rg_game_maps[rg_map_now(background) + RG_MAP_ROWS]

def rg_in_map?(background, row, col)
  row >= 0 && row < rg_map_rows(background) && col >= 0 && col < rg_map_cols(background)
end

# Where a cell of the map is among its cells, which are kept row after row.
def rg_cell_place(background, row, col) = (row * rg_map_cols(background)) + col

# Reference#map_of: what a cell holds NOW, in the run's own copy where there is one. Below nought
# where it holds no tile.
def rg_map_cell(background, row, col)
  return RG_CELL_EMPTY unless rg_in_map?(background, row, col)

  own = @rg_cells_now[rg_keeper_of(background)][1]
  return own[rg_cell_place(background, row, col)] if own

  @rg_game_map_cells[@rg_game_maps[rg_map_now(background) + RG_MAP_CELLS] + rg_cell_place(background, row, col)]
end

# The name's cells become the run's own copy of map number +which+ of the maps of the declaration
# up now, as that map was declared (Reference#mutable_map, and the copy in #exec_show_map).
def rg_copy_map(background, which)
  up = rg_declaration_up(background)
  map = rg_map_entry(up, which)
  count = @rg_game_maps[map + RG_MAP_COLS] * @rg_game_maps[map + RG_MAP_ROWS]
  first = @rg_game_maps[map + RG_MAP_CELLS]
  @rg_cells_now[rg_keeper_of(background)] = [which, @rg_game_map_cells[first, count], up]
end

# Each background with the name is drawn from its own first map again, as declared.
def rg_forget_own_cells(background)
  @rg_cells_now[rg_keeper_of(background)] = [0, nil, 0]
end

# The start of Reference#take_over: a background coming up as a scene takes over goes up as
# declared, so the cells the game changed of its name are forgotten before anything is painted.
def rg_background_forget_cells(background) = rg_forget_own_cells(background)

# One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel), in the colors the
# background is drawn with now (Reference#tile_colors): its tiles as drawn with each step come one
# whole set after another. A tile the game paints is read from what it last copied in, and shown in
# its run's colors as the background is drawn with them now.
def rg_tile_pixel(background, cell, tx, ty)
  painted = rg_background_field(background, RG_BG_PAINTED)
  if painted != RG_NOT_PAINTED && @rg_game_painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
    run = @rg_game_painted_tiles[painted + (2 * cell)]
    which = @rg_game_painted_tiles[painted + (2 * cell) + 1]
    # A big tile is kept as four squares, left to right and then down.
    if rg_background_field(background, RG_BG_TILE_W) == 2 * RG_RUN_TILE_SIDE
      which = (which * 4) + ((ty / RG_RUN_TILE_SIDE) * 2) + (tx / RG_RUN_TILE_SIDE)
      tx %= RG_RUN_TILE_SIDE
      ty %= RG_RUN_TILE_SIDE
    end
    place = rg_painted_places[rg_run_field(run, RG_RUN_PLACES) + (which * RG_RUN_TILE_PIXELS) + (ty * RG_RUN_TILE_SIDE) + tx]
    set = (rg_tile_set_now(background) * @rg_game_picture_sizes[RG_SIZE_RUNS]) + run
    return @rg_game_run_colors[rg_background_field(background, RG_BG_RUN_COLORS) + (set * RG_PLACES_IN_RUN_COLORS) + place]
  end
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  tile = (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES)) + cell
  @rg_game_tile_pixels[rg_background_field(background, RG_BG_TILES_START) + (tile * tile_w * tile_h) + (ty * tile_w) + tx]
end

# Reference#grid_repeats: how many times the grid is seen along one side of the screen.
def rg_grid_repeats(background, grid_cells, screen_side)
  return 1 if rg_background_field(background, RG_BG_NEVER_WRAPS) != 0 ||
              rg_background_field(background, RG_BG_TILE_W) != 8 || rg_background_field(background, RG_BG_TILE_H) != 8

  (screen_side + (grid_cells * 8) - 1) / (grid_cells * 8)
end

# The map onto the picture with its corner at (left, top), cell by cell.
def rg_stamp_map_at(background, left, top)
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  rg_map_rows(background).times do |row|
    rg_map_cols(background).times do |col|
      cell = rg_map_cell(background, row, col)
      next if cell < 0

      tile_h.times do |ty|
        tile_w.times do |tx|
          color = rg_tile_pixel(background, cell, tx, ty)
          rg_set_pixel(left + (col * tile_w) + tx, top + (row * tile_h) + ty, color) if color != RG_SEE_THROUGH
        end
      end
    end
  end
end

# Reference#stamp_background: the whole map onto the picture, as many times as the screen sees it.
def rg_background_stamp(background)
  # Reference#stamp_background: a status bar is painted from its own top as the view is built.
  return rg_request_repaint if rg_bar?(background) || rg_held_above_row?(background) || rg_held_to_box?(background)

  rg_mix_as_layer(rg_background_field(background, RG_BG_SEE_THROUGH))
  map = rg_map_now(background)
  grid_cols = @rg_game_maps[map + RG_MAP_GRID_COLS]
  grid_rows = @rg_game_maps[map + RG_MAP_GRID_ROWS]
  across = rg_grid_repeats(background, grid_cols, RG_SCREEN_WIDTH)
  rg_grid_repeats(background, grid_rows, RG_SCREEN_HEIGHT).times do |round_down|
    across.times { |round_across| rg_stamp_map_at(background, round_across * grid_cols * 8, round_down * grid_rows * 8) }
  end
  rg_mix_nothing
end

def rg_stack_place(background) = rg_background_field(background, RG_BG_STACK_PLACE)

# Reference#behind?: only when both named a layer.
def rg_behind?(a, b)
  rg_stack_place(a) != RG_NO_LAYER && rg_stack_place(b) != RG_NO_LAYER && rg_stack_place(a) < rg_stack_place(b)
end

# Whether an entry of the list is among those being put in order: every one, or (+over+ a
# background) only the ones a named layer puts in front of it.
def rg_in_order_asked?(entry, over) = over < 0 || rg_behind?(over, entry)

# Where the LAST entry for +background+ lands once the entries asked for are put in the order the
# stack asks for (IR::Stacking.order_by_stack), counting from 0 among them, or -1 when it has no
# entry. An entry that named no layer stays where it is. The ones that did are sorted by how far
# forward their layers are — two in one layer keeping the order they came in — and handed, in that
# order, the places the named entries held.
def rg_last_place_in_stack_order(background, over)
  place = rg_stack_place(background)
  at = -1
  last = -1
  further_back = 0
  in_its_layer = 0
  in_its_layer_by_last = 0
  @rg_shown_backgrounds.each do |entry|
    next unless rg_in_order_asked?(entry, over)

    at += 1
    entry_place = rg_stack_place(entry)
    further_back += 1 if entry_place != RG_NO_LAYER && entry_place < place
    in_its_layer += 1 if entry_place != RG_NO_LAYER && entry_place == place
    if entry == background
      last = at
      in_its_layer_by_last = in_its_layer
    end
  end
  return last if last < 0 || place == RG_NO_LAYER

  # It is the named entry number +nth+ in sorted order, so it takes the place of the named entry
  # number +nth+ in the order they went up.
  nth = further_back + in_its_layer_by_last - 1
  named = -1
  at = -1
  @rg_shown_backgrounds.each do |entry|
    next unless rg_in_order_asked?(entry, over)

    at += 1
    if rg_stack_place(entry) != RG_NO_LAYER
      named += 1
      return at if named == nth
    end
  end
  -1
end

# Reference#in_stack_order over the scenery that is up — all of it, or the part a named layer puts
# in front of +over+ — with each one stamped in that order. Stamping one again paints over every
# stamp of it before, so only where the last entry for each background lands decides the picture,
# and each is stamped once, in the order of those places.
def rg_stamp_in_stack_order(over)
  return if over >= 0 && rg_stack_place(over) == RG_NO_LAYER

  lands = Array.new(@rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) { |bg| rg_last_place_in_stack_order(bg, over) }
  loop do
    nxt = -1
    lands.each_index { |bg| nxt = bg if lands[bg] >= 0 && (nxt < 0 || lands[bg] < lands[nxt]) }
    return if nxt < 0

    rg_background_stamp(nxt)
    lands[nxt] = -1
  end
end

# Reference#put_up_background. A stamp only covers where it has solid pixels, so a background a
# named layer puts BEHIND one already up would land in front of it; the ones it belongs behind are
# stamped again over it. A turned background is painted through its turn at the next rebuild.
def rg_background_put_up(background)
  # A change still waiting to this background's name was made to cells put up again now; the
  # changes to every other background are kept, in the order made.
  keeper = rg_keeper_of(background)
  @rg_held_tiles.reject! { |change, _, _, _| rg_keeper_of(change) == keeper }
  if rg_background_field(background, RG_BG_ON_ARRIVAL) != 0
    rg_forget_own_cells(background)
    @rg_boxes[rg_keeper_of(background)] = nil # its scene puts it up showing everywhere
  end
  @rg_shown_backgrounds << background
  rg_mark_from_corner(background)
  @rg_scenery_kept = false
  return rg_request_repaint if @rg_turns[rg_keeper_of(background)].turned || rg_bar?(background) ||
                               rg_held_above_row?(background) || rg_bar_showing || rg_held_to_box?(background) ||
                               rg_placed_fade_in_picture?

  rg_background_stamp(background)
  rg_stamp_in_stack_order(background)
end

# Reference#exec_affine_background: the angle wraps into 0..359 as Ruby's % does.
def rg_background_turn(background, angle, size, pivot_x, pivot_y)
  @rg_turns[rg_keeper_of(background)] = RgTurn.new(true, angle % 360, size, pivot_x, pivot_y)
  rg_request_repaint
end

# Reference#showing_scenery: scenery every screen shows, and the running scene's own.
def rg_showing?(background)
  scene = rg_background_field(background, RG_BG_SCENE)
  scene == RG_EVERY_SCENE || scene == @rg_scene
end

# Reference#exec_scroll_background
# The interpreter builds the view again every time; this builds it again only when the scroll the
# picture shows is not the one it was built with, so a frame that sets the same scroll again costs
# nothing. What the picture shows is what rg_scroll_shown answers, which for a background put up
# this pass is its corner, so a scroll set over a corner is a change even where the number written
# is the one already stored.
def rg_background_scroll(background, x, y)
  keeper = rg_keeper_of(background)
  before = rg_scroll_shown(background)
  @rg_scrolls[keeper] = [x, y]
  @rg_from_corner[keeper] = false unless @rg_placing_at_pass_end
  after = rg_scroll_shown(background)
  return rg_request_repaint if after[0] != before[0] || after[1] != before[1]

  rg_skip_repaint
end

# Whether a background is a status bar (RG_BG_BAR_TOP).
def rg_bar?(background) = rg_background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR

# Reference#exec_place_bar
def rg_place_bar(background, top)
  keeper = rg_keeper_of(background)
  @rg_bar_tops[keeper] = rg_clamp_wide(top, 0, RG_SCREEN_HEIGHT)
  @rg_bar_placed[keeper] = true
  @rg_from_corner[keeper] = false unless @rg_placing_at_pass_end
  rg_request_repaint
end

# Reference#exec_box_background and #screen_box: a box with nothing on the screen is an empty one at
# the corner.
def rg_background_box(background, x, y, width, height, held)
  @rg_boxes[rg_keeper_of(background)] = held.zero? ? nil : rg_screen_box(x, y, width, height)
  rg_request_repaint
end

def rg_screen_box(x, y, width, height)
  return [0, 0, 0, 0] if width <= 0 || height <= 0

  left = rg_clamp_wide(x, 0, RG_SCREEN_WIDTH)
  right = rg_clamp_wide(x + width, 0, RG_SCREEN_WIDTH)
  top = rg_clamp_wide(y, 0, RG_SCREEN_HEIGHT)
  bottom = rg_clamp_wide(y + height, 0, RG_SCREEN_HEIGHT)
  right <= left || bottom <= top ? [0, 0, 0, 0] : [left, top, right, bottom]
end

# Whether a background is held to a box (Reference @bg_box).
def rg_held_to_box?(background) = !@rg_boxes[rg_keeper_of(background)].nil?

# Reference#exec_place_bar's covers
def rg_bar_covers(background, covers)
  @rg_bar_covers[rg_keeper_of(background)] = covers != 0
  rg_request_repaint
end

# Reference#bar_top_shown
def rg_bar_top_shown(bar)
  declared = rg_clamp_wide(rg_background_field(bar, RG_BG_BAR_TOP), 0, RG_SCREEN_HEIGHT)
  keeper = rg_keeper_of(bar)
  @rg_from_corner[keeper] || !@rg_bar_placed[keeper] ? declared : @rg_bar_tops[keeper]
end

# Reference#bar_showing: the status bar on screen, or nil.
def rg_bar_showing
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times.find { |bg| rg_showing?(bg) && rg_bar?(bg) }
end

# Reference#scenery_rows
def rg_scenery_rows
  bar = rg_bar_showing
  bar ? rg_bar_top_shown(bar) : RG_SCREEN_HEIGHT
end

# Reference#rows_shown_of
def rg_rows_shown_of(background)
  above = rg_background_field(background, RG_BG_ABOVE_ROW)
  above == RG_NOT_A_BAR ? rg_scenery_rows : [rg_scenery_rows, above].min
end

# Whether a background is held above a row of the screen.
def rg_held_above_row?(background) = rg_background_field(background, RG_BG_ABOVE_ROW) != RG_NOT_A_BAR

# Reference#paint_status_bar_rows: from its top row to the bottom of the screen, its map from its own
# corner, never scrolled; past the end of its map the backdrop stays. A row in a block that starts
# above the bar reads the bar's map above its first row, where its grid comes round.
def rg_paint_status_bar_rows(bar)
  top = rg_bar_top_shown(bar)
  grid_h = @rg_game_maps[rg_map_now(bar) + RG_MAP_GRID_ROWS] * rg_background_field(bar, RG_BG_TILE_H)
  (top...RG_SCREEN_HEIGHT).each do |py|
    my = rg_row_drawn_from(py) - top
    next if my.negative? && grid_h.zero?

    my %= grid_h if my.negative?
    rg_paint_map_row(bar, my, 0, nil, py)
  end
end

# Reference#paint_status_bar: the status bar as drawn, or in blocks while the picture is shown in them and
# the game puts its bar there too (RG_BG_IN_BLOCKS), in the one grid from the screen's top.
def rg_paint_status_bar(bar)
  block = rg_hook_block_size
  return rg_paint_status_bar_rows(bar) if block == 1 || rg_background_field(bar, RG_BG_IN_BLOCKS).zero?

  @rg_sheet.fill(RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = true
  @rg_rows_tall = block
  rg_paint_status_bar_rows(bar)
  @rg_onto_sheet = false
  @rg_rows_tall = 1
  (rg_bar_top_shown(bar)...RG_SCREEN_HEIGHT).each do |py|
    RG_SCREEN_WIDTH.times do |px|
      color = @rg_sheet[(py * RG_SCREEN_WIDTH) + px - (px % block)]
      rg_lay_scenery(px, py, color) if color != RG_NOTHING_ON_SHEET
    end
  end
end

# Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. A cell is
# kept as a signed sixteen-bit number, as the map's cells are.
def rg_background_set_tile(background, col, row, tile)
  # A tile only another scene's declaration of the name has changes nothing here.
  return if tile >= rg_background_field(rg_declaration_up(background), RG_BG_TILES)

  keeper = rg_keeper_of(background)
  rg_copy_map(background, 0) unless @rg_cells_now[keeper][1]
  return unless rg_in_map?(background, row, col)

  cells = @rg_cells_now[keeper][1]
  place = rg_cell_place(background, row, col)
  return if cells[place] == tile

  cells[place] = rg_to_half(tile)
  rg_request_repaint
end

# Reference#exec_set_tile, held: the change waits, its cell worked out now. With +most+ waiting,
# everything waiting goes in first.
def rg_background_hold_tile(background, col, row, tile, most)
  return if tile >= rg_background_field(rg_declaration_up(background), RG_BG_TILES)

  rg_show_held_tiles if @rg_held_tiles.length >= most
  @rg_held_tiles << [background, col, row, tile]
end

# Reference#exec_show_held_tiles
def rg_show_held_tiles
  waiting = @rg_held_tiles
  @rg_held_tiles = []
  waiting.each { |background, col, row, tile| rg_background_set_tile(background, col, row, tile) }
end

# Reference#exec_show_map: of the maps of the declaration up now.
def rg_background_show_map(background, which)
  return if which < 0 || which >= rg_background_field(rg_declaration_up(background), RG_BG_SHOWABLE_MAPS)

  rg_copy_map(background, which)
  rg_request_repaint
end

# Reference#exec_background_colors: the next rebuild reads the tiles in the colors named. The number
# is kept for the name, and what it names is worked out for each entry as it is drawn
# (rg_tile_set_now).
def rg_background_draw_with(background, which)
  @rg_colors_told[rg_keeper_of(background)] = which.negative? ? 0 : which + 1
  rg_request_repaint
end

# rg_tiled.c's rg_background_follow: the tiles a background draws from one of several lists it
# follows are copied from set number +set+ of its tiles over the ones the picture is drawn from.
def rg_background_follow(rules, set)
  background = rules[1]
  tile_size = rg_background_field(background, RG_BG_TILE_W) * rg_background_field(background, RG_BG_TILE_H)
  start = rg_background_field(background, RG_BG_TILES_START)
  set_size = rg_background_field(background, RG_BG_TILES) * tile_size
  changed = false
  rules[2].times do |i|
    to = start + (rules[3 + i] * tile_size)
    wanted = @rg_game_tile_pixels[to + (set * set_size), tile_size]
    next if @rg_game_tile_pixels[to, tile_size] == wanted

    @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
    @rg_game_tile_pixels[to, tile_size] = wanted
    changed = true
  end
  rg_request_repaint if changed
end

# Framebuffer#paint_row, a cell at a time: one color of scenery laid on the picture at (px, py),
# which is on the screen, mixed and faded as whatever is in force sets.
def rg_lay_scenery(px, py, color)
  at = (py * RG_SCREEN_WIDTH) + px
  painted = rg_into_cell(color, @rg_pixels[at], @rg_pixels, at)
  @rg_pixels[at] = painted
  @rg_picture_without_sprites[at] = painted if rg_sprites_seen_through?
end

# The row of the picture that screen row +py+ is drawn from: its own, or the row at the top of its
# block while a background is being painted for blocks.
def rg_row_drawn_from(py) = py - (py % @rg_rows_tall)

def rg_bend_asked(background) = background == @rg_asked_bend[0] ? 1 : 0
def rg_bend_line = @rg_asked_bend[1]

def rg_bend_answer(offset)
  @rg_asked_bend[2] = offset
end

# Reference#run_bend_for_row: the game asked how far across line +py+ of the background that keeps
# the name sits, after running whatever is in its block.
def rg_run_bend_for_line(keeper, py)
  @rg_asked_bend[0] = keeper
  @rg_asked_bend[1] = py
  rg_game_bend_offsets
  @rg_asked_bend[0] = RG_NOBODY_ASKED
  @rg_asked_bend[2]
end

# Lines +first_line+ up to +past_line+ of one background, worked out in turn and kept.
def rg_bend_work_out(background, first_line, past_line)
  keeper = rg_keeper_of(background) # the game answers for the name
  lines = @rg_bend_lines[keeper] ||= Array.new(RG_SCREEN_HEIGHT, 0)
  (first_line...past_line).each { |py| lines[py] = rg_run_bend_for_line(keeper, py) }
end

# Reference#work_out_bends, last in every frame boundary of a game that bends a background it has:
# every bend's lines are worked out, and the picture is owed again.
def rg_screen_work_out_bends
  rg_game_work_out_bends
  rg_request_repaint if @rg_frames_begun
end

# Reference#bend_offset_at: how far across line +py+ of the screen a background sits, on top of its
# scroll, as the gap between frames last worked it out. Before the first gap: flat for a game that
# waits for the screen, and worked out as the line is painted for one that never waits. Nought for
# a background the game does not bend.
def rg_bend_at(background, py)
  return 0 if rg_background_field(background, RG_BG_BENT) == 0

  keeper = rg_keeper_of(background)
  lines = @rg_bend_lines[keeper]
  return lines[py] if lines

  @rg_frames_begun ? 0 : rg_run_bend_for_line(keeper, py)
end

# Reference#paint_streamed_background_window: a background with a map too big for any grid, or with
# maps of different sizes, does not come round again: past any edge of its map there are no cells.
def rg_paint_window_without_wrapping(background)
  map_h = rg_map_rows(background) * rg_background_field(background, RG_BG_TILE_H)
  scroll_x, scroll_y = rg_scroll_shown(background)
  rg_rows_shown_of(background).times do |py|
    my = scroll_y + rg_row_drawn_from(py)
    next if my < 0 || my >= map_h

    rg_paint_map_row(background, my, scroll_x + rg_bend_at(background, py), nil, py)
  end
end

# ONE ROW OF THE SCREEN FROM ONE ROW OF A BACKGROUND'S MAP (Reference#paint_background_window, a row
# at a time): the screen's pixel px shows map column off_x + px, taken round at +wrap_w+ where the
# map wraps, or not at all (nil) where it does not. +my+ is not below nought. Where the map has no
# cell or no tile, or the tile is see-through, what is behind stays.
#
# Which map is up, how big it is, its tiles' size and the tile set in use cannot change while a row
# is painted, so they are asked once here, and a cell is looked up once for each tile the row
# crosses rather than for each pixel. A painted tile is read the slow way (rg_tile_pixel), since
# where its pixels are depends on the cell.
#
# What this asks of the background is rg_map_cell and rg_tile_pixel written out, and so is what
# rg_paint_turned_window asks; and the plain pixel it lays is rg_lay_scenery's. A change to how
# cells, tile sets or a laid pixel are kept changes those three places too. The checked run holds
# all of it to the interpreter, pixel for pixel.
def rg_paint_map_row(background, my, off_x, wrap_w, py)
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  keeper = rg_keeper_of(background)
  map = rg_map_now(background)
  cols = @rg_game_maps[map + RG_MAP_COLS]
  row = my / tile_h
  return if row >= @rg_game_maps[map + RG_MAP_ROWS]

  own = @rg_cells_now[keeper][1]
  cells = own || @rg_game_map_cells
  first = (own ? 0 : @rg_game_maps[map + RG_MAP_CELLS]) + (row * cols)
  ty = my % tile_h
  tile_size = tile_w * tile_h
  set_start = rg_background_field(background, RG_BG_TILES_START) +
              (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES) * tile_size) + (ty * tile_w)
  painted = rg_background_field(background, RG_BG_PAINTED)
  painted_tiles = @rg_game_painted_tiles
  pixels = @rg_game_tile_pixels
  sheet = @rg_onto_sheet ? @rg_sheet : nil
  sheet_row = py * RG_SCREEN_WIDTH
  # With no fade painted in and no see-through layer being mixed, rg_lay_scenery comes to storing
  # the color, marking the cell as no mix and keeping it in the picture without sprites where
  # that is kept; so that is done here.
  plain = !@rg_paint_fade && !@rg_mixing
  picture = @rg_pixels
  mixed_cells = @rg_picture_mixes.is_mixed
  without_sprites = rg_sprites_seen_through? ? @rg_picture_without_sprites : nil
  # A tile's width of the row at a time: the screen pixels from px that show one tile's row, which
  # end at the tile's right edge or the screen's. Where the map wraps it wraps at a whole number of
  # tiles, so a tile is never cut by the wrap.
  px = 0
  while px < RG_SCREEN_WIDTH
    mx = off_x + px
    mx %= wrap_w if wrap_w
    if mx < 0 # only where the map does not wrap: nothing until the map's left edge
      px -= mx
      next
    end
    col = mx / tile_w
    tx = mx - (col * tile_w)
    run = tile_w - tx
    run = RG_SCREEN_WIDTH - px if run > RG_SCREEN_WIDTH - px
    cell = col < cols ? cells[first + col] : RG_CELL_EMPTY
    if cell >= 0
      slow = painted != RG_NOT_PAINTED && painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
      from = set_start + (cell * tile_size) + tx
      i = 0
      while i < run
        color = slow ? rg_tile_pixel(background, cell, tx + i, ty) : pixels[from + i]
        if color != RG_SEE_THROUGH
          at = sheet_row + px + i
          if sheet
            sheet[at] = color
          elsif plain
            color &= 0xFFFF
            picture[at] = color
            mixed_cells[at] = 0
            without_sprites[at] = color if without_sprites
          else
            rg_lay_scenery(px + i, py, color)
          end
        end
        i += 1
      end
    end
    px += run
  end
end

# Reference#paint_background_window, for a background never turned: the window sits where the
# background is scrolled to, the map wraps over the console's whole grid, and a row or cell past the
# map shows what is behind.
def rg_paint_window(background)
  return rg_paint_window_without_wrapping(background) if rg_background_field(background, RG_BG_NEVER_WRAPS) != 0

  map = rg_map_now(background)
  map_w = @rg_game_maps[map + RG_MAP_GRID_COLS] * rg_background_field(background, RG_BG_TILE_W)
  map_h = @rg_game_maps[map + RG_MAP_GRID_ROWS] * rg_background_field(background, RG_BG_TILE_H)
  return if map_w == 0 || map_h == 0

  scroll_x, scroll_y = rg_scroll_shown(background)
  off_y = scroll_y % map_h
  rg_rows_shown_of(background).times do |py|
    off_x = (scroll_x + rg_bend_at(background, py)) % map_w
    my = (off_y + rg_row_drawn_from(py)) % map_h
    rg_paint_map_row(background, my, off_x, map_w, py)
  end
end

# Reference#paint_affine_background_window: for each screen pixel, work back through the turn to
# the map pixel that lands there, from wherever the background is scrolled to.
def rg_paint_turned_window(background)
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  map = rg_map_now(background)
  map_w = @rg_game_maps[map + RG_MAP_GRID_COLS] * tile_w
  map_h = @rg_game_maps[map + RG_MAP_GRID_ROWS] * tile_h
  return if map_w == 0 || map_h == 0

  keeper = rg_keeper_of(background)
  turn = @rg_turns[keeper]
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(turn.angle, turn.size)
  # A turned layer is placed by its turn, which putting it up leaves as it is.
  scroll_x, scroll_y = @rg_scrolls[keeper]
  pivot_x = turn.pivot_x
  pivot_y = turn.pivot_y
  # What rg_map_cell and rg_tile_pixel ask of the background, asked once: nothing the game does
  # runs while a turned layer is painted, so none of it can change (see rg_paint_map_row).
  cols = @rg_game_maps[map + RG_MAP_COLS]
  rows = @rg_game_maps[map + RG_MAP_ROWS]
  own = @rg_cells_now[keeper][1]
  cells = own || @rg_game_map_cells
  first = own ? 0 : @rg_game_maps[map + RG_MAP_CELLS]
  tile_size = tile_w * tile_h
  set_start = rg_background_field(background, RG_BG_TILES_START) +
              (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES) * tile_size)
  painted = rg_background_field(background, RG_BG_PAINTED)
  painted_tiles = @rg_game_painted_tiles
  pixels = @rg_game_tile_pixels
  sheet = @rg_onto_sheet ? @rg_sheet : nil
  rows_painted = rg_scenery_rows
  py = 0
  while py < rows_painted
    dy = rg_row_drawn_from(py) - pivot_y
    # The two sums, turn_cos * dx + turn_sin * dy and -turn_sin * dx + turn_cos * dy, at the row's
    # first pixel, where dx is -pivot_x. dx goes up by one a pixel, so each sum moves on by its step
    # (turn_cos, and -turn_sin) for every pixel after: the same whole numbers the products give,
    # with no multiply a pixel.
    sum_x = (turn_cos * -pivot_x) + (turn_sin * dy)
    sum_y = (turn_sin * pivot_x) + (turn_cos * dy)
    last_row = -1
    last_col = -1
    cell = RG_CELL_EMPTY
    start = 0
    slow = false
    px = 0
    while px < RG_SCREEN_WIDTH
      mx = (scroll_x + pivot_x + (sum_x / one_th)) % map_w
      my = (scroll_y + pivot_y + (sum_y / one_th)) % map_h
      row = my / tile_h
      col = mx / tile_w
      if row != last_row || col != last_col
        last_row = row
        last_col = col
        cell = row < rows && col < cols ? cells[first + (row * cols) + col] : RG_CELL_EMPTY
        if cell >= 0
          slow = painted != RG_NOT_PAINTED && painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
          start = set_start + (cell * tile_size)
        end
      end
      if cell >= 0
        tx = mx % tile_w
        ty = my % tile_h
        color = slow ? rg_tile_pixel(background, cell, tx, ty) : pixels[start + (ty * tile_w) + tx]
        if color != RG_SEE_THROUGH
          if sheet
            sheet[(py * RG_SCREEN_WIDTH) + px] = color
          else
            rg_set_pixel(px, py, color)
          end
        end
      end
      sum_x += turn_cos
      sum_y -= turn_sin
      px += 1
    end
    py += 1
  end
end

# Reference#paint_background_window: one background painted where it sits in the view.
def rg_paint_background(background)
  if @rg_turns[rg_keeper_of(background)].turned
    rg_paint_turned_window(background)
  else
    rg_paint_window(background)
  end
end

# Reference#paint_scenery_in_blocks: ONE BACKGROUND IN BLOCKS of +block+ pixels each way, by the
# display's own rule, while the picture is shown in them (rg_hook_block_size).
#
# The blocks are fixed to the screen, and each shows the color the background has at the block's
# top left corner, so a background that scrolls slides under a grid that stays where it is. A
# corner that is see-through leaves the whole block see-through.
#
# Down and across are done apart, because a display draws a row at a time. Down: every row of a
# block is drawn from the map row its top row shows, and still placed by its OWN bend, so a
# background bent row by row keeps each row's bend and a block of it is a sheared one. Across:
# each pixel of a row then takes the one at the start of its block in that same row. So the
# background goes onto the sheet rows first, and is laid on the picture through the blocks, with
# whatever mix or fade is in force for it applied as it is laid. A background held to a box keeps
# to the box as it is laid (+box+, or nil).
#
# Reference#block_width_across: a background that can turn is left one pixel wide at a size of
# two, so its rows double and its columns do not. That is the emulator's, kept because the
# console's picture is checked against it.
def rg_paint_scenery_in_blocks(background, block, box)
  @rg_sheet.fill(RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = true
  @rg_rows_tall = block
  rg_paint_background(background)
  @rg_onto_sheet = false
  @rg_rows_tall = 1
  wide = rg_background_field(background, RG_BG_CAN_TURN) != 0 && block == 2 ? 1 : block
  rg_scenery_rows.times do |py|
    RG_SCREEN_WIDTH.times do |px|
      next if box && (px < box[0] || px >= box[2] || py < box[1] || py >= box[3])

      color = @rg_sheet[(py * RG_SCREEN_WIDTH) + px - (px % wide)]
      rg_lay_scenery(px, py, color) if color != RG_NOTHING_ON_SHEET
    end
  end
end

# Reference#paint_scenery_in_box: a background held to a box goes onto the sheet as it would onto
# the picture, and only its pixels inside the box are laid on the picture.
def rg_paint_scenery_in_box(background, box)
  left, top, right, bottom = box
  @rg_sheet.fill(RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = true
  rg_paint_background(background)
  @rg_onto_sheet = false
  (top...bottom).each do |py|
    (left...right).each do |px|
      color = @rg_sheet[(py * RG_SCREEN_WIDTH) + px]
      rg_lay_scenery(px, py, color) if color != RG_NOTHING_ON_SHEET
    end
  end
end

# Reference#paint_scenery: a background held to a box with nothing in it paints nothing; one the
# game has not left as drawn is painted in blocks while the blocks are bigger than a pixel.
def rg_paint_scenery(background)
  box = @rg_boxes[rg_keeper_of(background)]
  return if box && (box[2] <= box[0] || box[3] <= box[1])

  block = rg_hook_block_size
  if block > 1 && rg_background_field(background, RG_BG_IN_BLOCKS) != 0
    rg_paint_scenery_in_blocks(background, block, box)
  elsif box
    rg_paint_scenery_in_box(background, box)
  else
    rg_paint_background(background)
  end
end

# Reference#set_blend_for, for scenery: what is painted next is mixed as the layer the background
# is in, and faded unless a placed fade leaves it as drawn.
def rg_blend_as_background(background)
  rg_mix_as_layer(rg_background_field(background, RG_BG_SEE_THROUGH))
  rg_fade_unless_left_as_drawn(rg_background_field(background, RG_BG_FADE_PLACE))
end

# --- the hooks it takes ---

# The state of the scenery. Scenery up, in the order it went up (Reference @bg_shown): one entry for
# every time a background is put up, even one already up, exactly as the interpreter keeps it.
def rg_tiled_setup
  # A background laid on the picture a part at a time (inside a box it is held to, or in blocks) is
  # painted onto a sheet of its own first, every row the map row +@rg_rows_tall+ rows above it at
  # most (Reference#paint_scenery_in_blocks).
  @rg_sheet = Array.new(RG_SCREEN_CELLS, RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = false
  @rg_rows_tall = 1
  @rg_shown_backgrounds = []
  # What the game does to a background, kept by the entry that keeps its NAME (rg_keeper_of): the
  # map its cells hold now, the run's own copy of them and the entry whose map that is (Reference
  # @bg_maps, kept as [which, cells, of]), its scroll (@bg_scroll), whether it is shown from its
  # corner this pass (@bg_from_corner), the step of colors the game last named for it, from which
  # each entry works out the set of its tiles it is drawn from (@bg_colors), and its turn
  # (@bg_affine).
  @rg_cells_now = Array.new(RG_MAX_BACKGROUNDS) { [0, nil, 0] }
  @rg_scrolls = Array.new(RG_MAX_BACKGROUNDS) { [0, 0] }
  @rg_from_corner = Array.new(RG_MAX_BACKGROUNDS, false)
  @rg_bar_tops = Array.new(RG_MAX_BACKGROUNDS, 0) # where each status bar was last placed
  @rg_bar_placed = Array.new(RG_MAX_BACKGROUNDS, false) # ...and whether it has been
  # The box each is held to (@bg_box): left, top, and the column and row just past it, kept to the
  # screen (Reference#screen_box), or nil where it shows everywhere.
  @rg_boxes = Array.new(RG_MAX_BACKGROUNDS)
  # The cell changes of backgrounds declared `held: true`, waiting for rg_show_held_tiles (Reference
  # @held_tiles), each [background, col, row, tile], in the order the game made them.
  @rg_held_tiles = []
  @rg_bar_covers = Array.new(RG_MAX_BACKGROUNDS, false) # ...and whether it hides the sprites under it
  @rg_any_from_corner = false
  @rg_corners_expired = false
  @rg_colors_told = Array.new(RG_MAX_BACKGROUNDS, 0) # one more than the step of colors last named, 0 for none
  @rg_turns = Array.new(RG_MAX_BACKGROUNDS) { RgTurn.new(false, 0, 0, 0, 0) }
  # Bends: the background and line being asked about and the answer, and every line of every bent
  # background as the gap between frames last worked it out.
  @rg_asked_bend = [RG_NOBODY_ASKED, 0, 0]
  @rg_bend_lines = Array.new(RG_MAX_BACKGROUNDS)
  @rg_bar_in_rebuild = nil
end

# Reference#exec_screen: a screen of another kind wipes the scenery, and arriving on one drawn
# from tiles puts up again what every such screen shows, as declared (#put_up_always_up).
def rg_tiled_screen_crossed(new_kind)
  @rg_shown_backgrounds = []
  return if new_kind == RG_BITMAP

  @rg_game_picture_sizes[RG_SIZE_ALWAYS_UP].times do |i|
    rg_forget_own_cells(@rg_game_always_up[i])
    rg_background_put_up(@rg_game_always_up[i])
  end
end

# The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its
# picture is painted (Reference#forget_expired_corners).
def rg_tiled_frame_ended
  @rg_corners_expired = true if @rg_any_from_corner
end

def rg_tiled_repaint_requested = rg_forget_expired_corners
def rg_tiled_rebuild_checked = rg_forget_expired_corners

# A status bar is painted first: no background is painted under it, so it is in front of all of
# them and every sprite is painted over it. The bar on screen is kept in @rg_bar_in_rebuild, from
# here to rg_tiled_repaint_ending, or nil.
def rg_tiled_repaint_began
  @rg_bar_in_rebuild = rg_bar_showing
  bar = @rg_bar_in_rebuild
  return unless bar

  rg_blend_as_background(bar)
  rg_paint_status_bar(bar)
end

def rg_tiled_paint_level(level)
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times do |bg|
    next if !rg_showing?(bg) || rg_background_field(bg, RG_BG_LEVEL) != level

    rg_blend_as_background(bg)
    rg_paint_scenery(bg)
  end
end

# Reference#paint_bar_over_sprites
def rg_tiled_repaint_ending
  bar = @rg_bar_in_rebuild
  @rg_bar_in_rebuild = nil
  return if !bar || !@rg_bar_covers[rg_keeper_of(bar)]

  top = rg_bar_top_shown(bar)
  rg_mix_nothing
  rg_fade_unless_left_as_drawn(RG_NO_LAYER)
  rg_fill_cells(0, top, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT - top, @rg_backdrop)
  rg_blend_as_background(bar)
  rg_paint_status_bar(bar)
end

# Reference#scene_framebuffer: every background showing, stamped.
def rg_tiled_stamp_scenery
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times { |bg| rg_background_stamp(bg) if rg_showing?(bg) }
end

def rg_tiled_scenery_up = !@rg_shown_backgrounds.empty?

# Reference#layer_has_anything?, for scenery: a background showing now in that layer.
def rg_tiled_layer_holds_scenery(layer)
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times.any? do |bg|
    rg_showing?(bg) && rg_background_field(bg, RG_BG_SEE_THROUGH) == layer
  end
end

# Reference#take_down_scenery: the last scene's own scenery comes down, and the picture goes back
# to the scenery every screen shows. Answers whether any came down.
def rg_tiled_scene_take_down(brings_scenery)
  any_scene_owned = @rg_shown_backgrounds.any? { |bg| rg_background_field(bg, RG_BG_SCENE) != RG_EVERY_SCENE }
  return false if !any_scene_owned && brings_scenery == 0

  rg_screen_paint_owed_rebuild
  kept = @rg_shown_backgrounds.select { |bg| rg_background_field(bg, RG_BG_ON_ARRIVAL) == 0 }
  return false if kept.length == @rg_shown_backgrounds.length

  @rg_shown_backgrounds = kept
  @rg_scenery_kept = false
  rg_clear_to(@rg_backdrop)
  rg_stamp_in_stack_order(-1)
  rg_request_repaint if rg_placed_fade_in_picture? # a placed fade stays across the change
  true
end

# --- the state image (rg_tiled.c says what each field holds) ---

RG_MOST_SCENERY_PUT_UP = 1 << 28   # rg_tiled.c's remember_put_up's limit
RG_HELD_TILES_ROOM = 1024          # rg_tiled.h's

# "tiled": whether backgrounds are shown from their corners this pass and whether that pass has
# ended, how many times scenery has been put up, and how many tile changes wait.
RgSceneryFields = Data.define(:any_from_corner, :corners_expired, :put_up, :changes_waiting)

# "tiled.held", one a change waiting: the background, the cell, and the tile.
RgHeldTile = Data.define(:background, :col, :row, :tile)

# "tiled.backgrounds", one a background, by the entry that keeps its name: whether it has cells
# of its own and the map they copy, its scroll, whether it is shown from its corner, the colours
# last named, its box (nought throughout where it is held to none), its turn, where its status bar
# was placed and whether, whether the bar covers the sprites, and whether its bends were worked out.
RgBackgroundFields = Data.define(:own_cells, :map_which, :map_of, :scroll_x, :scroll_y, :from_corner, :colors_told,
                                :boxed, :box_left, :box_top, :box_right, :box_bottom,
                                :turned, :angle, :size, :pivot_x, :pivot_y,
                                :bar_top, :bar_placed, :bar_covers, :bends_kept)

# How many cells a copy of map +which+ of entry +of+ holds.
def rg_map_copy_cell_count(of, which)
  map = rg_map_entry(of, which)
  @rg_game_maps[map + RG_MAP_COLS] * @rg_game_maps[map + RG_MAP_ROWS]
end

# How many cells a background's own copy holds, by its fields: none where it has no copy.
def rg_own_copy_cell_count(fields) = fields.own_cells.zero? ? 0 : rg_map_copy_cell_count(fields.map_of, fields.map_which)

def rg_background_fields(background)
  which, cells, of = @rg_cells_now[background]
  left, top, right, bottom = @rg_boxes[background] || [0, 0, 0, 0]
  turn = @rg_turns[background]
  x, y = @rg_scrolls[background]
  RgBackgroundFields.new(
    own_cells: rg_state_flag(!cells.nil?), map_which: which, map_of: of, scroll_x: x, scroll_y: y,
    from_corner: rg_state_flag(@rg_from_corner[background]), colors_told: @rg_colors_told[background],
    boxed: rg_state_flag(!@rg_boxes[background].nil?), box_left: left, box_top: top, box_right: right, box_bottom: bottom,
    turned: rg_state_flag(turn.turned), angle: turn.angle, size: turn.size, pivot_x: turn.pivot_x, pivot_y: turn.pivot_y,
    bar_top: @rg_bar_tops[background], bar_placed: rg_state_flag(@rg_bar_placed[background]),
    bar_covers: rg_state_flag(@rg_bar_covers[background]), bends_kept: rg_state_flag(!@rg_bend_lines[background].nil?)
  )
end

# A background's fields read from the image, all but its cells and its bends.
def rg_read_background_fields(background, fields)
  if fields.own_cells != 0 && (!fields.map_of.between?(0, @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS] - 1) ||
                              fields.map_which.negative? ||
                              (fields.map_which.positive? && fields.map_which >= rg_background_field(fields.map_of, RG_BG_SHOWABLE_MAPS)))
    rg_state_refuse_damaged("a background holds a map it does not have")
  end
  @rg_cells_now[background] = [fields.map_which, nil, fields.map_of]
  @rg_scrolls[background] = [fields.scroll_x, fields.scroll_y]
  @rg_from_corner[background] = fields.from_corner != 0
  @rg_colors_told[background] = fields.colors_told
  @rg_boxes[background] = (fields.boxed != 0 ? [fields.box_left, fields.box_top, fields.box_right, fields.box_bottom] : nil)
  @rg_turns[background] = RgTurn.new(fields.turned != 0, fields.angle, fields.size, fields.pivot_x, fields.pivot_y)
  @rg_bar_tops[background] = fields.bar_top
  @rg_bar_placed[background] = fields.bar_placed != 0
  @rg_bar_covers[background] = fields.bar_covers != 0
end

# rg_hook_visit_state (rg_tiled.c's rg_tiled_visit_state): the scenery up and the changes waiting,
# then what each background's name keeps, the cells of its own copy, and the lines of its bends.
def rg_tiled_visit_state
  backgrounds = @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]
  scenery = rg_state_record("tiled", RgSceneryFields.new(
                                       any_from_corner: rg_state_flag(@rg_any_from_corner),
                                       corners_expired: rg_state_flag(@rg_corners_expired),
                                       put_up: @rg_shown_backgrounds.length, changes_waiting: @rg_held_tiles.length
                                     ))
  unless scenery.put_up.between?(0, RG_MOST_SCENERY_PUT_UP - 1) && scenery.changes_waiting.between?(0, RG_HELD_TILES_ROOM)
    rg_state_refuse_damaged("the scenery holds more than it can")
  end
  @rg_any_from_corner = scenery.any_from_corner != 0
  @rg_corners_expired = scenery.corners_expired != 0

  shown = rg_state_numbers("tiled.shown", rg_state_reading ? Array.new(scenery.put_up, 0) : @rg_shown_backgrounds.dup)
  unless shown.all? { |bg| bg.between?(0, backgrounds - 1) }
    rg_state_refuse_damaged("the scenery up names a background the game does not have")
  end
  @rg_shown_backgrounds = shown

  changes = rg_state_records("tiled.held", @rg_held_tiles.map { |change| RgHeldTile.new(*change) }, RgHeldTile,
                             scenery.changes_waiting)
  unless changes.all? { |change| change.background.between?(0, backgrounds - 1) }
    rg_state_refuse_damaged("a tile change waits for a background the game does not have")
  end
  @rg_held_tiles = changes.map { |change| [change.background, change.col, change.row, change.tile] }

  background_fields = rg_state_records("tiled.backgrounds", Array.new(backgrounds) { |bg| rg_background_fields(bg) },
                            RgBackgroundFields, backgrounds)
  background_fields.each_with_index { |fields, bg| rg_read_background_fields(bg, fields) } if rg_state_reading

  owners = background_fields.each_index.reject { |bg| background_fields[bg].own_cells.zero? }
  sizes = owners.map { |bg| rg_own_copy_cell_count(background_fields[bg]) }
  cells = rg_state_numbers("tiled.cells",
                           rg_state_reading ? Array.new(sizes.sum, 0) : owners.flat_map { |bg| @rg_cells_now[bg][1] })
  if rg_state_reading
    owners.zip(sizes).each { |bg, size| @rg_cells_now[bg][1] = cells.shift(size).map { |cell| rg_to_half(cell) } }
  end

  bent_backgrounds = background_fields.each_index.reject { |bg| background_fields[bg].bends_kept.zero? }
  lines = rg_state_numbers("tiled.bends",
                           if rg_state_reading
                             Array.new(bent_backgrounds.length * RG_SCREEN_HEIGHT, 0)
                           else
                             bent_backgrounds.flat_map { |bg| @rg_bend_lines[bg] }
                           end)
  return unless rg_state_reading

  @rg_bend_lines = Array.new(RG_MAX_BACKGROUNDS)
  bent_backgrounds.each { |bg| @rg_bend_lines[bg] = lines.shift(RG_SCREEN_HEIGHT) }
end
