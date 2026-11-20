# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A MAP BIGGER THAN THE CONSOLE'S GRID, brought into view a strip at a time.
        #
        # The console draws a background from a grid of cells in its video memory, and the
        # biggest grid it has is 64x64 cells — four screens. A room bigger than that cannot be
        # put in the grid whole. But the screen only ever shows 31 columns and 21 rows of cells
        # (30 by 20, and one more each way while the view sits part way across a cell), and the
        # grid comes round again at its edge: scroll past its right side and the display reads
        # its left side. So a 32x32 grid is enough to show any part of any map, as long as the
        # cells around the view hold the right part of the map when the picture is drawn.
        #
        # That is what this keeps true. The whole map stays in the cartridge, row after row, and
        # each frame, in the gap before the picture, the place the view is scrolled to is
        # compared with the place the grid was last filled for. A view that moved a cell to the
        # right has one new column coming in on the right; it is copied in over the column that
        # just left on the left, which is the same place in the grid. Rows the same way. Retail
        # games draw their big rooms exactly like this.
        #
        # A JUMP — a new map, a scene taking over, or a view that moved more than a few cells at
        # once — fills the whole view again instead, row by row, in that same gap. So the frame
        # the view lands on already shows the right picture.
        #
        # Past the edge of the map there are no cells, and the blank cell (every pixel
        # see-through) is copied in there. That is why such a map does not come round again the
        # way a map that fits its grid does (see IR::TileMap.streams?).
        #
        # WHAT IT COSTS: a frame the view stayed inside the same cell copies nothing, and pays a
        # few dozen instructions to find that out — where the view is, which map, and four
        # comparisons. A frame it crossed one copies a column of 21 cells or a row of 31, a
        # handful of instructions a cell. A jump is the whole view, 21 rows of 31, each row handed
        # to the copying engine in one to four copies.
        module MapStreaming
          include Console::Hardware

          # The cells the screen can show at once, each way: 240 and 160 pixels over 8-pixel
          # cells, and one more for a view part way across a cell.
          VIEW_COLS = 31
          VIEW_ROWS = 21

          # The grid such a background has in video memory: one block of 32x32 cells.
          STREAM_CELLS = 32

          # A view that moved further than this many cells since the last frame is filled again
          # whole. Copying that many columns or rows one by one would cost more than the fill.
          MOST_STRIPS = 8

          # A map's four words in the table of maps (see ScreenLayout::StreamedMaps): how far into
          # the blob it starts, its columns, its rows and its blank cell. Sixteen bytes, so a
          # map's row is found with a shift.
          MAP_ROW_SHIFT = 4

          # The registers the strip copy keeps across the whole fill: the map in the cartridge,
          # its columns and rows, the grid in video memory and the blank cell.
          STREAM_SOURCE = 6
          STREAM_COLS = 7
          STREAM_ROWS = 8
          STREAM_GRID = 10
          STREAM_BLANK = 11

          # The registers one strip is described in: the first cell's column and row, how many
          # cells, and how far each step moves along a row and down a column.
          STRIP_COL = 2
          STRIP_ROW = 3
          STRIP_COUNT = 4
          STRIP_ACROSS = 5
          STRIP_DOWN = 9

          # ...and the one a cell's place is worked out in, beside ACC and TMP.
          STRIP_SCRATCH = 12

          # The registers a whole fill works in (see #emit_view_fill): the row of the map it is
          # on, where that row starts in the grid, and the copying engine's first register.
          FILL_ROW = 12
          FILL_GRID_ROW = 9
          FILL_COPIER = 11

          # The registers one run of a row is described in (see #emit_row_piece_routine): the
          # grid column it starts at, how many cells, the engine's control bits, and where the
          # cells are read from.
          PIECE_COL = 2
          PIECE_COUNT = 3
          PIECE_CONTROL = 4
          PIECE_SOURCE = 5

          STACK_POINTER = 13

          # Where a fill keeps three words on the stack, in bytes from its top: the view's first
          # column, the row past its last, and the blank cell.
          FILL_FIRST_COL = 0
          FILL_END_ROW = 4
          FILL_BLANK = 8

          # The variables this keeps for one background: the column and row the grid was last
          # filled for, and the column and row the view is at now.
          def stream_var(name, what) = :"_stream_#{name}_#{what}"

          # The routine that brings one such background's view along its map (see
          # #emit_stream_view_routine). Named for the background, so a report and a measured
          # profile can say whose it is — and for the +scene+ too, for a background declared in
          # several, which has one for each scene's declaration (see
          # ScreenLayout#declared_background).
          def self.view_routine(name, scene: nil)
            return Messages::MadeNames.make(:view_along_map, background: name) unless scene

            Messages::MadeNames.make(:view_along_map_in_scene, background: name, scene: IR::Modes.strip_scene_prefix(scene))
          end

          # The routine that changes one cell of such a background's map (see
          # #emit_map_cell_write_routine), named as #view_routine is.
          def self.cell_write_routine(name, scene: nil)
            return Messages::MadeNames.make(:map_cell_write, background: name) unless scene

            Messages::MadeNames.make(:map_cell_write_in_scene, background: name, scene: IR::Modes.strip_scene_prefix(scene))
          end

          # BRING THE CELLS AROUND THE VIEW IN, for a background whose map is brought into view a
          # strip at a time (+stream+, its StreamedMaps), before its scroll registers are
          # written. +x+ and +y+ are the values that hold where the view is now, in the map's own
          # pixels.
          #
          # What is written here is where the view is and a call. The work is a routine of the
          # background's own, because it is wanted in three places — the scroll write every
          # frame, the background going up, and an area's tiles coming in — and written out at
          # each it was the larger part of all three.
          def emit_stream_view(stream, x, y)
            emit_view_cell(x, stream_var(stream.name, :want_col))
            emit_view_cell(y, stream_var(stream.name, :want_row))
            @lowering.statement(Build.call(stream.routine))
          end

          # THE BODY OF THAT ROUTINE: compare the cell the view is at now with the cell the grid
          # was last filled for, and copy in the strips between the two, or the whole view.
          #
          # It is a routine the build places like one somebody wrote, by what a frame spends in
          # it, so a game that scrolls a big map can keep it in the quick memory while there is
          # room. That matters most on the frame the whole view is filled: twenty-one rows, a few
          # dozen instructions and a copy or two a row, in a gap the layers are switched off for.
          def emit_stream_view_routine(bg)
            name = bg.stream.name
            refill = gensym
            columns_left = gensym
            rows_down = gensym
            rows_up = gensym
            done = gensym
            strip = gensym
            piece = gensym

            emit_stream_source(bg)

            filled = IR::Nodes::Background.stream_vars(name).last
            load_var(ACC, filled)
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, refill, cond: :eq) # a new map, or a scene that just took over
            emit_far_move_check(stream_var(name, :col), stream_var(name, :want_col), refill)
            emit_far_move_check(stream_var(name, :row), stream_var(name, :want_row), refill)

            # Columns coming in on the right: the one just past the right edge of what is held.
            emit_strip_steps(name, :col, :want_col, toward: :up, strip: strip, done: columns_left) do |at|
              emit(ASM.add_imm(STRIP_COL, at, VIEW_COLS))
              load_var(STRIP_ROW, stream_var(name, :row))
              emit_column_strip
            end
            place_label(columns_left)
            emit_strip_steps(name, :col, :want_col, toward: :down, strip: strip, done: rows_down) do |at|
              emit(ASM.mov_reg(STRIP_COL, at))
              load_var(STRIP_ROW, stream_var(name, :row))
              emit_column_strip
            end
            place_label(rows_down)
            emit_strip_steps(name, :row, :want_row, toward: :up, strip: strip, done: rows_up) do |at|
              emit(ASM.add_imm(STRIP_ROW, at, VIEW_ROWS))
              load_var(STRIP_COL, stream_var(name, :col))
              emit_row_strip
            end
            place_label(rows_up)
            emit_strip_steps(name, :row, :want_row, toward: :down, strip: strip, done: done) do |at|
              emit(ASM.mov_reg(STRIP_ROW, at))
              load_var(STRIP_COL, stream_var(name, :col))
              emit_row_strip
            end
            emit_branch(:b, done)

            place_label(refill)
            emit_view_fill(bg.stream.routine, name, filled, piece)

            # The copy of one strip and of one piece of a row, called from the places above.
            # They sit here, jumped over, so they move wherever the routine around them is put.
            place_label(done)
            after = gensym
            emit_branch(:b, after)
            place_label(strip)
            emit_strip_routine(bg.stream.routine)
            place_label(piece)
            emit_row_piece_routine
            place_label(after)
          end

          # FILL THE WHOLE VIEW NOW, from the place the background's view is at and the map it
          # names, rather than in the scroll write later in the gap. For the moments the layers
          # are switched off — a scene taking over, an area's tiles coming in — so the view is
          # whole by the time they are on again, and no part of the frame shows the last room's
          # cells over the new tiles.
          #
          # +at_corner+ fills round the map's top-left corner instead, for a background that
          # is being put up and whose scroll is put back there with it.
          def emit_stream_fill(bg, at_corner: false)
            name = bg.stream.name
            emit_number(ACC, 0)
            store_var(ACC, IR::Nodes::Background.stream_vars(name).last)
            x, y = at_corner ? [Build.int(0), Build.int(0)] : IR::Nodes::Background.scroll_vars(name).map { |var| Build.var_ref(var) }
            emit_stream_view(bg.stream, x, y)
          end

          # HAND THE BACKGROUND ANOTHER MAP: set which map the strips come from now, and mark that the
          # grid does not hold it yet. Nothing is copied here. The scroll write later in the
          # same gap fills the whole view from the new map, at the place the view is at then,
          # so the frame shows the new map wherever the game moved the view to on the way in.
          # A number naming no map changes nothing.
          def emit_stream_map_change(node, bg, done)
            streamed, filled = IR::Nodes::Background.stream_vars(node.name)
            @lowering.value(node.which)
            emit(ASM.cmp_imm(ACC, bg.map_count))
            emit_branch(:bcond, done, cond: :hs)
            store_var(ACC, streamed)
            emit_number(ACC, 0)
            store_var(ACC, filled)
            # A map the game changes is copied again, as declared, even the one already showing.
            store_var(ACC, stream_var(node.name, :copied)) if bg.stream.kept
          end

          private

          # The cell a view's place in pixels starts in, kept in +var+. A view to the left of or
          # above the map is a negative place, and shifting keeps the sign, so it is still the
          # cell the view starts in.
          def emit_view_cell(value, var)
            @lowering.value(value)
            emit(ASM.asr_imm(ACC, ACC, 3))
            store_var(ACC, var)
          end

          # The map the strips come from: where it starts in the cartridge, its size and its
          # blank cell. Read off the table of maps by the number the background last showed —
          # which is always a map it has, since a number naming none is never stored there. For a
          # map the game changes, its copy in the roomy memory (#emit_kept_map_source).
          def emit_stream_source(bg)
            stream = bg.stream
            streamed, = IR::Nodes::Background.stream_vars(stream.name)
            load_var(ACC, streamed)
            emit(ASM.lsl_imm(ACC, ACC, MAP_ROW_SHIFT))
            emit_load_data_address(TMP, stream.table)
            emit(ASM.add_reg(TMP, TMP, ACC))
            emit(ASM.ldr_offset(STREAM_SOURCE, TMP, 0))
            emit(ASM.ldr_offset(STREAM_COLS, TMP, 4))
            emit(ASM.ldr_offset(STREAM_ROWS, TMP, 8))
            emit(ASM.ldr_offset(STREAM_BLANK, TMP, 12))
            emit_load_data_address(TMP, stream.maps)
            emit(ASM.add_reg(STREAM_SOURCE, STREAM_SOURCE, TMP))
            emit_kept_map_source(stream) if stream.kept
            emit_number(STREAM_GRID, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES))
          end

          # A MAP THE GAME CHANGES (`set_tile`) is kept in the roomy memory while it is showing, and
          # its strips come from there, so a changed cell scrolled out of view comes back changed. A
          # console's own games keep a big room's cells in work memory the same way and bring each
          # strip into the grid from there. The copy is made the first time it is wanted after
          # show_map hands the background a map, or after the background goes up, by the copying
          # engine (GBATEK, "DMA Transfers": DMA3, halfwords), which then holds the cells until the
          # next. The whole copy is made before the routine goes on, so every cell the strips read
          # or `set_tile` writes is in it, and no changed cell is ever copied over. A frame that
          # wants no new copy pays a load, an add and a compare to find that out.
          #
          # A BIG MAP IS COPIED IN PIECES of KEPT_COPY_PIECE_CELLS cells at most, one after another.
          # The engine holds the processor and the screen's interrupt only while one piece moves, and
          # the processor takes an interrupt waiting for it between two pieces, so the sound mixer's
          # hand-over is never held off longer than one piece (#KEPT_COPY_PIECE_CELLS). A map of up
          # to that many cells is one piece, as it always was.
          #
          # Comes in with the map's place in the cartridge in STREAM_SOURCE and its size in
          # STREAM_COLS and STREAM_ROWS, and leaves STREAM_SOURCE at the copy.
          def emit_kept_map_source(stream)
            streamed, = IR::Nodes::Background.stream_vars(stream.name)
            copied = stream_var(stream.name, :copied)
            have = gensym
            load_var(ACC, streamed)
            emit(ASM.add_imm(ACC, ACC, 1)) # the copy notes its map's number and one, so nought is none
            load_var(TMP, copied)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, have, cond: :eq)
            store_var(ACC, copied)
            if stream.kept_bytes / 2 > KEPT_COPY_PIECE_CELLS
              emit_kept_map_copy_in_pieces(stream)
            else
              emit_number(STRIP_COL, REG_DMA3SAD)
              emit(ASM.str_offset(STREAM_SOURCE, STRIP_COL, 0))
              emit_number(ACC, kept_map_address(stream))
              emit(ASM.str_offset(ACC, STRIP_COL, Primitives::COPY_TO_STEP))
              emit(ASM.mul(ACC, STREAM_COLS, STREAM_ROWS))
              emit_number(TMP, DMA_ENABLE | DMA_16BIT)
              emit(ASM.orr_reg(ACC, ACC, TMP))
              emit(ASM.str_offset(ACC, STRIP_COL, Primitives::COPY_START_STEP))
            end
            place_label(have)
            emit_number(STREAM_SOURCE, kept_map_address(stream))
          end

          # The copy of #emit_kept_map_source for a background whose biggest map is more than one
          # piece: KEPT_COPY_PIECE_CELLS cells a piece, the last piece what is left. Works in the
          # strip registers, which the strips and the cell write set again after.
          def emit_kept_map_copy_in_pieces(stream)
            again = gensym
            from = STRIP_ROW
            to = STRIP_COUNT
            piece = STRIP_ACROSS
            control = STRIP_DOWN
            emit_number(STRIP_COL, REG_DMA3SAD)
            emit(ASM.mov_reg(from, STREAM_SOURCE))
            emit_number(to, kept_map_address(stream))
            emit_number(piece, KEPT_COPY_PIECE_CELLS)
            emit_number(control, DMA_ENABLE | DMA_16BIT)
            emit(ASM.mul(ACC, STREAM_COLS, STREAM_ROWS)) # the cells left to copy
            place_label(again)
            emit(ASM.cmp_reg(ACC, piece))
            emit(ASM.mov_reg(TMP, ACC))
            emit(ASM.mov_reg_cond(:gt, TMP, piece)) # this piece: what is left, no more than a piece
            emit(ASM.str_offset(from, STRIP_COL, 0))
            emit(ASM.str_offset(to, STRIP_COL, Primitives::COPY_TO_STEP))
            emit(ASM.orr_reg(STRIP_SCRATCH, TMP, control))
            emit(ASM.str_offset(STRIP_SCRATCH, STRIP_COL, Primitives::COPY_START_STEP))
            emit(ASM.add_reg_lsl(from, from, TMP, 1)) # two bytes a cell
            emit(ASM.add_reg_lsl(to, to, TMP, 1))
            emit(ASM.subs_reg(ACC, ACC, TMP))
            emit_branch(:bcond, again, cond: :ne)
          end

          # Where the copy of a map the game changes is kept: room in the roomy memory for the
          # biggest of the background's maps, one for each declaration.
          def kept_map_address(stream)
            (@kept_map_addresses ||= {})[stream.routine] ||=
              @memory.alloc_roomy(stream.kept_bytes) or
              raise LoweringError, "background :#{stream.name} has a map of #{stream.kept_bytes / 2} cells, and the game " \
                                   "changes its cells. The console's roomy memory is full, so there is no room for a copy " \
                                   "of that map. To fix this, use smaller maps."
          end

          # HOW LONG ONE PIECE OF THE COPY HOLDS THE SCREEN'S INTERRUPT OFF. The copying engine holds
          # the processor, and the screen's interrupt with it, until a piece is across (GBATEK, "DMA
          # Transfers"). A cell is a halfword read from the cartridge, a sequential access of two
          # cycles at the wait states the game runs with (Console::Hardware::WAITCNT_FAST), and one
          # written to the roomy memory, three cycles for a halfword (GBATEK, "GBA Memory Map": two
          # wait states). The sound mixer is built to hand over its buffer up to Mixer::LATE_ROOM
          # late, which it sets from the longest copy the framework makes while a game runs, a
          # whole-screen clear of a fifth of a frame. So a piece is held to that fifth too, and the
          # sound never breaks for it: a fifth of a frame's 228 lines of 1232 cycles is under 46
          # lines.
          KEPT_COPY_CYCLES_A_CELL = 5
          KEPT_COPY_PIECE_CELLS = Console::ADVANCE.cycles_a_frame / 5 / KEPT_COPY_CYCLES_A_CELL

          public

          # THE ROUTINE THAT CHANGES ONE CELL OF A MAP THE GAME CHANGES (`set_tile`), called with the
          # cell's column and row and its new map entry in the background's own variables
          # (#emit_streamed_tile_write). The cell is written in the copy (#emit_kept_map_source), and
          # in the grid too where the grid holds it now, so it shows on the frame being drawn. A cell
          # outside the grid comes in from the copy when a strip brings it into view. A cell
          # outside the map changes nothing.
          #
          # It keeps the two registers a fast `repeat` holds its count and limit in
          # (LoopForm::COUNTER, LIMIT), which the stream source lands in, so a cell changed inside
          # such a loop leaves the loop counting: one save and one restore a cell written, where
          # counting the loop in memory would cost every pass of every loop that writes a cell.
          def emit_map_cell_write_routine(bg)
            name = bg.stream.name
            done = gensym
            emit(ASM.push(LoopForm::COUNTER, LoopForm::LIMIT))
            emit_stream_source(bg)
            load_var(STRIP_COL, stream_var(name, :write_col))
            load_var(STRIP_ROW, stream_var(name, :write_row))
            # One unsigned compare catches both ends, as in the strip copy.
            emit(ASM.cmp_reg(STRIP_COL, STREAM_COLS))
            emit_branch(:bcond, done, cond: :hs)
            emit(ASM.cmp_reg(STRIP_ROW, STREAM_ROWS))
            emit_branch(:bcond, done, cond: :hs)
            load_var(STRIP_COUNT, stream_var(name, :write_cell))
            emit(ASM.mul(TMP, STRIP_ROW, STREAM_COLS))
            emit(ASM.add_reg(TMP, TMP, STRIP_COL))
            emit(ASM.add_reg_lsl(TMP, STREAM_SOURCE, TMP, 1)) # two bytes a cell
            emit(ASM.store_halfword(STRIP_COUNT, TMP))
            # The grid holds VIEW_COLS columns and VIEW_ROWS rows from the place it was last
            # filled for, once it has been filled for this map.
            load_var(ACC, IR::Nodes::Background.stream_vars(name).last)
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, done, cond: :eq)
            load_var(ACC, stream_var(name, :col))
            emit(ASM.sub_reg(ACC, STRIP_COL, ACC))
            emit(ASM.cmp_imm(ACC, VIEW_COLS))
            emit_branch(:bcond, done, cond: :hs)
            load_var(ACC, stream_var(name, :row))
            emit(ASM.sub_reg(ACC, STRIP_ROW, ACC))
            emit(ASM.cmp_imm(ACC, VIEW_ROWS))
            emit_branch(:bcond, done, cond: :hs)
            emit(ASM.and_imm(TMP, STRIP_ROW, STREAM_CELLS - 1))
            emit(ASM.lsl_imm(TMP, TMP, 5))
            emit(ASM.and_imm(STRIP_SCRATCH, STRIP_COL, STREAM_CELLS - 1))
            emit(ASM.orr_reg(TMP, TMP, STRIP_SCRATCH))
            emit(ASM.add_reg_lsl(TMP, STREAM_GRID, TMP, 1))
            emit(ASM.store_halfword(STRIP_COUNT, TMP))
            place_label(done)
            emit(ASM.pop(LoopForm::COUNTER, LoopForm::LIMIT))
          end

          # ONE CELL OF A MAP BROUGHT IN A STRIP AT A TIME CHANGED (`set_tile`): its column, row and
          # map entry handed to the background's own routine (#emit_map_cell_write_routine), so the
          # cell stays changed in the copy the strips come from.
          def emit_streamed_tile_write(node, bg, entry)
            name = bg.stream.name
            @lowering.value(node.col)
            store_var(ACC, stream_var(name, :write_col))
            @lowering.value(node.row)
            store_var(ACC, stream_var(name, :write_row))
            emit_number(ACC, entry)
            store_var(ACC, stream_var(name, :write_cell))
            @lowering.statement(Build.call(bg.stream.writer))
          end

          # The copy of a map the game changes is made again once something asks for it: after
          # show_map, and as the background goes up, when nothing is known to be copied yet.
          def emit_kept_map_forgotten(stream)
            emit_number(ACC, 0)
            store_var(ACC, stream_var(stream.name, :copied))
          end

          private

          # Go to +refill+ when the view moved more than MOST_STRIPS cells one way since the grid
          # was filled. One unsigned test covers both directions: the move plus MOST_STRIPS is
          # inside 0..2*MOST_STRIPS for a short move either way, and anything else, a negative
          # number included, reads as more.
          def emit_far_move_check(held, want, refill)
            load_var(ACC, want)
            load_var(TMP, held)
            emit(ASM.sub_reg(ACC, ACC, TMP))
            emit(ASM.add_imm(ACC, ACC, MOST_STRIPS))
            emit(ASM.cmp_imm(ACC, (2 * MOST_STRIPS) + 1))
            emit_branch(:bcond, refill, cond: :hs)
          end

          # Move the place the grid holds one cell at a time toward where the view is, copying
          # the strip that comes in at each step, until the two agree. +toward: :up+ is the
          # view to the right or below. The block gets the register holding the grid's place —
          # before the step going up, after it going down — and names the strip that comes in.
          def emit_strip_steps(name, held_what, want_what, toward:, strip:, done:)
            held = stream_var(name, held_what)
            want = stream_var(name, want_what)
            again = gensym
            place_label(again)
            load_var(ACC, held)
            load_var(TMP, want)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, done, cond: toward == :up ? :ge : :le)
            if toward == :up
              emit(ASM.add_imm(TMP, ACC, 1)) # the grid's place moves on; ACC keeps where it was
              store_var(TMP, held)
            else
              emit(ASM.sub_imm(ACC, ACC, 1))
              store_var(ACC, held)
            end
            yield ACC
            emit_branch(:bl, strip)
            emit_branch(:b, again)
          end

          # A strip down one column: VIEW_ROWS cells, each a row further down.
          def emit_column_strip
            emit_number(STRIP_COUNT, VIEW_ROWS)
            emit_number(STRIP_ACROSS, 0)
            emit_number(STRIP_DOWN, 1)
          end

          # A strip along one row: VIEW_COLS cells, each a column further right.
          def emit_row_strip
            emit_number(STRIP_COUNT, VIEW_COLS)
            emit_number(STRIP_ACROSS, 1)
            emit_number(STRIP_DOWN, 0)
          end

          # FILL THE WHOLE VIEW, a row at a time, for the place the view is at now, and mark that the
          # grid holds it.
          #
          # Each row is handed to the copying engine (GBATEK, "DMA Transfers": DMA3, halfwords)
          # rather than written a cell at a time, because a cell at a time is a loop of a bounds
          # test, a multiply and a store for every one of the 651 cells, and a fill comes in the
          # gap with the layers off. A row is at most three runs: blank cells left of the map,
          # the map's own cells, and blank cells right of it, and each run is one or two copies
          # (see #emit_row_piece_routine). A row above or below the map is one run of blanks.
          #
          # The blank cell is copied from the stack, with the engine reading the same halfword
          # over and over. So STREAM_BLANK's register is free during the fill, and holds the
          # engine's address instead.
          def emit_view_fill(routine, name, filled, piece)
            again = gensym
            map_cells = gensym
            blank_rest = gensym
            next_row = gensym
            load_var(ACC, stream_var(name, :want_col))
            store_var(ACC, stream_var(name, :col))
            load_var(TMP, stream_var(name, :want_row))
            store_var(TMP, stream_var(name, :row))
            emit(ASM.mov_reg(FILL_ROW, TMP))
            emit(ASM.add_imm(TMP, TMP, VIEW_ROWS))
            # Kept on the stack for the whole fill, since the registers are all taken: the view's
            # first column, the row past its last, and the blank cell.
            emit(ASM.push(ACC, TMP, STREAM_BLANK))
            emit_number(FILL_COPIER, REG_DMA3SAD)

            place_label(again)
            # Every row of the view writes VIEW_COLS cells, in whichever runs.
            @emitter.note_video_copy(Messages::MadeNames.words_for_made_name(routine), VIEW_COLS * 2)
            emit(ASM.and_imm(FILL_GRID_ROW, FILL_ROW, STREAM_CELLS - 1))
            emit(ASM.add_reg_lsl(FILL_GRID_ROW, STREAM_GRID, FILL_GRID_ROW, 6)) # 64 bytes a grid row
            emit(ASM.ldr_offset(PIECE_COL, STACK_POINTER, FILL_FIRST_COL))
            emit_number(PIECE_COUNT, VIEW_COLS)
            emit_blank_piece_source
            # Above or below the map, the whole row is blank. One unsigned test, as in the strip.
            emit(ASM.cmp_reg(FILL_ROW, STREAM_ROWS))
            emit_branch(:bcond, blank_rest, cond: :hs)
            emit(ASM.cmp_imm(PIECE_COL, 0))
            emit_branch(:bcond, map_cells, cond: :ge)
            emit(ASM.rsb_imm(PIECE_COUNT, PIECE_COL, 0)) # the cells left of the map...
            emit(ASM.cmp_imm(PIECE_COUNT, VIEW_COLS))
            emit(ASM.mov_imm_cond(:gt, PIECE_COUNT, VIEW_COLS)) # ...no more than the row holds
            emit_branch(:bl, piece)

            place_label(map_cells)
            emit_cells_left_in_row(next_row)
            emit(ASM.cmp_reg(PIECE_COL, STREAM_COLS))
            emit_branch(:bcond, blank_rest, cond: :ge) # the row is past the map's right edge
            emit(ASM.sub_reg(ACC, STREAM_COLS, PIECE_COL))
            emit(ASM.cmp_reg(PIECE_COUNT, ACC))
            emit(ASM.mov_reg_cond(:gt, PIECE_COUNT, ACC)) # no further than the map's right edge
            emit(ASM.mul(ACC, FILL_ROW, STREAM_COLS))
            emit(ASM.add_reg(ACC, ACC, PIECE_COL))
            emit(ASM.add_reg_lsl(PIECE_SOURCE, STREAM_SOURCE, ACC, 1)) # two bytes a cell
            emit_number(PIECE_CONTROL, DMA_ENABLE | DMA_16BIT)
            emit_branch(:bl, piece)
            emit_cells_left_in_row(next_row)
            emit_blank_piece_source
            place_label(blank_rest)
            emit_branch(:bl, piece)

            place_label(next_row)
            emit(ASM.add_imm(FILL_ROW, FILL_ROW, 1))
            emit(ASM.ldr_offset(ACC, STACK_POINTER, FILL_END_ROW))
            emit(ASM.cmp_reg(FILL_ROW, ACC))
            emit_branch(:bcond, again, cond: :lt)
            emit(ASM.pop(ACC, TMP, STREAM_BLANK))
            emit_number(ACC, 1)
            store_var(ACC, filled)
          end

          # PIECE_COUNT = the cells of the row still to write, from PIECE_COL to the view's right
          # edge, or a jump to +next_row+ when there are none.
          def emit_cells_left_in_row(next_row)
            emit(ASM.ldr_offset(ACC, STACK_POINTER, FILL_FIRST_COL))
            emit(ASM.add_imm(ACC, ACC, VIEW_COLS))
            emit(ASM.subs_reg(PIECE_COUNT, ACC, PIECE_COL))
            emit_branch(:bcond, next_row, cond: :eq)
          end

          # The next piece copies the blank cell kept on the stack, the same halfword each time.
          def emit_blank_piece_source
            emit_number(PIECE_CONTROL, DMA_ENABLE | DMA_16BIT | DMA_SRC_FIXED)
            emit(ASM.add_imm(PIECE_SOURCE, STACK_POINTER, FILL_BLANK))
          end

          # COPY ONE RUN OF A ROW INTO THE GRID: PIECE_COUNT cells (one or more) from
          # PIECE_SOURCE, starting at column PIECE_COL of the grid row at FILL_GRID_ROW, with the
          # engine's control bits in PIECE_CONTROL. Leaves PIECE_COL past the run.
          #
          # The grid is 32 cells across and the view comes round it, so a run that reaches the
          # grid's right edge goes on from its left edge: two copies, the second from where the
          # first stopped reading (unless the source is the one blank cell). The view is 31 cells
          # wide, so a run never comes round twice.
          #
          # GBATEK, "DMA Transfers": the engine starts as the control word is written and the
          # processor waits until it is done, so the next copy can be set up straight after.
          def emit_row_piece_routine
            done = gensym
            emit(ASM.and_imm(ACC, PIECE_COL, STREAM_CELLS - 1))
            emit(ASM.rsb_imm(TMP, ACC, STREAM_CELLS)) # cells before the grid's right edge
            emit(ASM.cmp_reg(PIECE_COUNT, TMP))
            emit(ASM.mov_reg_cond(:lt, TMP, PIECE_COUNT))
            emit(ASM.add_reg_lsl(ACC, FILL_GRID_ROW, ACC, 1))
            emit(ASM.str_offset(PIECE_SOURCE, FILL_COPIER, 0))
            emit(ASM.str_offset(ACC, FILL_COPIER, Primitives::COPY_TO_STEP))
            emit(ASM.orr_reg(ACC, PIECE_CONTROL, TMP))
            emit(ASM.str_offset(ACC, FILL_COPIER, Primitives::COPY_START_STEP))
            emit(ASM.add_reg(PIECE_COL, PIECE_COL, TMP))
            emit(ASM.subs_reg(PIECE_COUNT, PIECE_COUNT, TMP))
            emit_branch(:bcond, done, cond: :eq)
            # The rest, from the grid row's first cell.
            emit(ASM.tst_imm(PIECE_CONTROL, DMA_SRC_FIXED))
            emit(ASM.lsl_imm(TMP, TMP, 1))
            emit(ASM.add_reg_cond(:eq, PIECE_SOURCE, PIECE_SOURCE, TMP))
            emit(ASM.str_offset(PIECE_SOURCE, FILL_COPIER, 0))
            emit(ASM.str_offset(FILL_GRID_ROW, FILL_COPIER, Primitives::COPY_TO_STEP))
            emit(ASM.orr_reg(ACC, PIECE_CONTROL, PIECE_COUNT))
            emit(ASM.str_offset(ACC, FILL_COPIER, Primitives::COPY_START_STEP))
            emit(ASM.add_reg(PIECE_COL, PIECE_COL, PIECE_COUNT))
            place_label(done)
            emit(ASM.return)
          end

          # COPY ONE STRIP OF CELLS FROM THE MAP INTO THE GRID, as described in the STRIP
          # registers. A cell outside the map gets the blank cell. A cell's place in the grid is
          # its column and row each taken round 32, which is what lets the grid come round again
          # under the view.
          def emit_strip_routine(routine)
            again = gensym
            blank = gensym
            @emitter.note_video_copy(Messages::MadeNames.words_for_made_name(routine), 2)
            place_label(again)
            emit(ASM.mov_reg(ACC, STREAM_BLANK))
            # One unsigned compare catches both ends: a negative column or row reads as a very
            # large number, so anything outside 0...size fails the same test.
            emit(ASM.cmp_reg(STRIP_COL, STREAM_COLS))
            emit_branch(:bcond, blank, cond: :hs)
            emit(ASM.cmp_reg(STRIP_ROW, STREAM_ROWS))
            emit_branch(:bcond, blank, cond: :hs)
            emit(ASM.mul(TMP, STRIP_ROW, STREAM_COLS))
            emit(ASM.add_reg(TMP, TMP, STRIP_COL))
            emit(ASM.lsl_imm(TMP, TMP, 1)) # two bytes a cell
            emit(ASM.add_reg(TMP, TMP, STREAM_SOURCE))
            emit(ASM.load_halfword(ACC, TMP))
            place_label(blank)
            emit(ASM.and_imm(TMP, STRIP_ROW, STREAM_CELLS - 1))
            emit(ASM.lsl_imm(TMP, TMP, 5))
            emit(ASM.and_imm(STRIP_SCRATCH, STRIP_COL, STREAM_CELLS - 1))
            emit(ASM.orr_reg(TMP, TMP, STRIP_SCRATCH))
            emit(ASM.lsl_imm(TMP, TMP, 1))
            emit(ASM.add_reg(TMP, TMP, STREAM_GRID))
            emit(ASM.store_halfword(ACC, TMP))
            emit(ASM.add_reg(STRIP_COL, STRIP_COL, STRIP_ACROSS))
            emit(ASM.add_reg(STRIP_ROW, STRIP_ROW, STRIP_DOWN))
            emit(ASM.subs_imm(STRIP_COUNT, STRIP_COUNT, 1))
            emit_branch(:bcond, again, cond: :ne)
            emit(ASM.return)
          end
        end
      end
    end
  end
end
