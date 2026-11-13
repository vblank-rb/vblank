# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # A SCREEN MADE OF TILES. A console's display reads its backgrounds' maps as it draws each line, so a
          # game that scrolls one only writes where it now starts. The card a PC has reads nothing but a picture,
          # so the processor builds that picture from the maps, as the interpreter does (Reference#repaint_view),
          # into the game's picture, which is then sent as a painted screen's is.
          #
          # A BACKGROUND IS PUT UP by stamping its map onto the picture from the map's corner, as many times as its
          # grid comes round across the screen (Reference#stamp_background). Until the pass that put it up ends it
          # shows from its corner whatever it is scrolled to (FROM_CORNER), as on the console, where the scroll is
          # written only between frames.
          #
          # A SCROLL MAKES THE VIEW OWED: built again from the backdrop up, every background in the order the stack
          # asks for, the window of each where it is scrolled to, its map coming round at its grid's edge or, for
          # a map that does not fit a grid, shown once. It is not built where the scroll is written but where the
          # interpreter builds it: before the next step that is not one of those that leave it owed
          # (Reference.defers_repaint?, which the lowering asks), and as the pass ends.
          #
          # Every background is drawn a row of the screen at a time from a row of its map (rt_scenery_map_row):
          # the cell looked up once for each tile the row crosses, and that tile's row copied, its see-through
          # pixels left as they were.
          #
          # In the art segment, read through GS, each background has a record (RECORD), its tiles (a palette
          # entry a pixel) and its map (a word a cell, row after row); the view is built from them in an order written
          # into the code (#emit_view). In the data segment each has its scroll and whether it shows from its corner
          # (STATE).
          module Scenery
            # A background's record in the art segment: where its cells are, how many columns and rows of them are kept,
            # a tile's width and height, how wide and tall its grid is in pixels and whether its map comes round at the
            # grid's edge, how many times a stamp repeats it across and down and how far apart, how tall its map is in
            # pixels, where its STATE is in the data segment, where its tiles with see-through pixels start, and how far
            # past a tile's pixels its mask is; then where the row lengths of the map now in its cells are, where the
            # list of its maps is and how many there are.
            #
            # A CELL HOLDS WHERE ITS TILE'S PIXELS ARE in the art segment, or NO_TILE where it has no tile or a tile with
            # nothing but see-through pixels. A background's solid tiles come first and its tiles with see-through
            # pixels after (MIXED), each with its mask MASK_DELTA bytes further on: FFh for each see-through pixel, where
            # the pixel itself is nought. A map that comes round is kept as wide and tall as its grid, the cells past
            # the map's own holding NO_TILE.
            #
            # A CELL CAN BE CHANGED as the game runs, since the art segment is memory like any other: the record and
            # the cells are the game's to write. Whether a cell is inside the map is asked of the map's own rows, a
            # word for each row kept, with how many cells that row of the map has (nought for a row past the map's
            # last), so a row shorter than the others, or a map shorter than the rows kept, changes nothing past its
            # end, as the interpreter's map has nothing there (Reference#change_cell). A background with several maps
            # keeps each map's cells and row lengths as declared, and the list of their places, two words a map: the
            # cells of each row as many as that row has, so many rooms of a few rows fit. The map shown is laid out
            # in the cells, a row at a time, the rest of each row and every row past its last given NO_TILE
            # (Reference#exec_show_map). The cells are as many across and down as the biggest map's.
            #
            # A BACKGROUND DRAWN FROM ANOTHER LIST OF COLOURS (`background_colors`, Reference#background_swap) has its
            # tiles kept again for each list, every copy laid out as the first, so a cell names its tile in the
            # colours it was drawn in and +colors_offset+ is how far on the copy shown now is: nought for those.
            #
            # +corner_y+ is the row of the map the screen's top shows while the background shows from its corner: nought,
            # or for a status bar the row it was declared at, less than nought (a word with a sign). +above_row+ is the
            # row a background held above a row stops at (`above_row:`), or nought. +bends+ is where a bent background's
            # rows are kept in the data segment (Lowering::Scenery.bend_rows_place), or nought for one not bent. +scene+ is
            # nought for a background every screen shows, and one more than its scene's number for a scene's own, which
            # shows only while that scene is up (SceneHandover#showing).
            RECORD = %i[cells cols rows tile_w tile_h wrap_w wrap_h wraps across down step_x step_y map_h state mixed
                        mask_delta lengths maps map_count colors_offset corner_y above_row bends scene].freeze
            RECORD_BYTES = 48
            NO_TILE = 0xFFFF

            # THE CELL CHANGES HELD FOR THE FRAME'S END (`set_tile ..., held: true`, Reference#exec_set_tile), in the
            # order the game made them: each the place of its background's record, the place of its tile's pixels,
            # and its column and row. A column or row too big for a word is out of every map, and is kept as FFFFh,
            # which is too. With HELD_MOST waiting, the next change puts them all in first.
            HELD = "rt scenery held"
            HELD_COUNT = "rt scenery held count"
            HELD_AT = "rt scenery held at"
            HELD_KEPT = "rt scenery held kept"
            HELD_BYTES = 8
            HELD_MOST = Nodes::ShowHeldTiles::MOST_CELLS

            # A RUN OF TILES THE GAME PAINTS FROM A LIST (Nodes::TileRun, Reference#copy_run_tiles): in the art segment
            # each run has a header of four words, how many tiles of backgrounds it paints, where its colours are (a
            # palette entry for each of the sixteen places a pixel names), where its list of each byte's place in a
            # tile is (the place of the byte's left pixel; its right one is the next), and how many bytes of the list
            # a tile takes. Then a tile of a background each, three words: which item of the list its first byte is,
            # where its pixels are, and how far past them its mask is. A tile of a background a run paints is kept
            # with the tiles that have see-through pixels, so every pixel of it can be either.
            RUN_COUNT = 0
            RUN_COLORS = 2
            RUN_PLACES = 4
            RUN_TILE_BYTES = 6
            RUN_HEADER = 8
            RUN_ENTRY_BYTES = 6
            # What rt_scenery_paint_run keeps while it works: the list, the tile's first item, which byte of the tile,
            # where the tile's pixels are and how far its mask is, how many tiles are still to paint and where the
            # next one is said, and the run's header.
            RUN_WORDS = ["rt scenery run list", "rt scenery run item", "rt scenery run byte", "rt scenery run pixels",
                         "rt scenery run mask", "rt scenery run left", "rt scenery run entry", "rt scenery run header"].freeze

            # A background's place in the data segment: its scroll, whether it shows from its corner, the place the
            # view was last built showing it from, and whether it has been put up; for a status bar, whether it covers
            # the sprites (Reference @bar_covers); and whether it is held to a box (`box_background`), and the box,
            # its left, top, right and bottom, kept to the screen (Reference#screen_box).
            #
            # A STATUS BAR'S TOP is kept as its scroll: it is shown from the map's top-left corner, that many rows down
            # the screen, so its scroll is nought across and its top less than nought down (`place_bar`), and it is
            # placed, shown from its corner and built into the view as a scroll is.
            STATE_BYTES = 68
            SCROLL_X = 0
            SCROLL_Y = 4
            FROM_CORNER = 8
            BUILT_X = 12
            BUILT_Y = 16
            SHOWN = 20
            COVERS = 24
            BOXED = 28
            BOX_LEFT = 32
            BOX_TOP = 36
            BOX_RIGHT = 40
            BOX_BOTTOM = 44
            # A BACKGROUND THAT TURNS OR RESIZES (`affine_background`, Reference @bg_affine): whether it has ever been
            # turned, which it stays, its angle and size as the game last gave them, and the point of the screen it
            # turns about. Its scroll is where its map is moved from the screen's corner, which its turn sets.
            TURNED = 48
            ANGLE = 52
            SIZE = 56
            PIVOT_X = 60
            PIVOT_Y = 64
            STATES = "rt scenery states"

            OWED = "rt scenery owed" # the view must be built again before it is next shown
            EXPIRED = "rt scenery corners expired" # the pass that put backgrounds up has ended
            ANY_FROM_CORNER = "rt scenery any from corner"
            UP = "rt scenery up" # anything has been put up, so a new backdrop builds the view again
            PLACING = "rt scenery placing" # the end of a pass is placing the frame's writes
            BACKDROP = "rt scenery backdrop" # the palette entry wherever nothing is drawn
            # 1 while the picture is the view as last built, with nothing stamped or filled over it since, and the
            # backdrop it was built over.
            BUILT = "rt scenery built"
            BUILT_BACKDROP = "rt scenery built backdrop"
            # What a row's painting keeps while it works: where its row of cells begins and ends, where in a tile its row
            # of pixels is, a tile's width, where tiles with see-through pixels start and how far their masks are, whether
            # the map comes round, and the map's column the screen's first pixel shows.
            ROW_BEGIN = "rt scenery row begin"
            ROW_END = "rt scenery row end"
            ROW_OFFSET = "rt scenery row offset"
            TILE_W = "rt scenery tile w"
            MIXED = "rt scenery mixed"
            MASK_DELTA = "rt scenery mask delta"
            COLORS_OFFSET = "rt scenery colors offset"
            WRAPS = "rt scenery wraps"
            OFF_X = "rt scenery off x"
            # What the stamp, the window and the view keep while they work.
            PY = "rt scenery py"
            MY = "rt scenery my"
            ROUND = "rt scenery round"
            SCROLL_SHOWN_X = "rt scenery shown x"
            SCROLL_SHOWN_Y = "rt scenery shown y"
            # THE PART OF THE SCREEN A WINDOW IS PAINTED IN, left, top, right and bottom, the right and bottom just past
            # it: the whole screen, or less for a background under a status bar, held above a row, under one shown
            # alone above its row, or held to a box (Reference#rows_shown_of, #box_shown_of).
            CLIP_LEFT = "rt scenery clip left"
            CLIP_TOP = "rt scenery clip top"
            CLIP_RIGHT = "rt scenery clip right"
            CLIP_BOTTOM = "rt scenery clip bottom"
            # As the view is built: the rows from the top the backgrounds are seen in (down to a status bar's top,
            # Reference#scenery_rows), the record of the status bar showing (nought for none), and the row and record of
            # a background shown alone above its row (Reference#row_held_alone_by_another).
            SCENERY_ROWS = "rt scenery rows"
            BAR_RECORD = "rt scenery bar record"
            ALONE_ROW = "rt scenery alone row"
            ALONE_RECORD = "rt scenery alone record"
            # A status bar has been put up, or a background shown alone above its row, so a background put up is built
            # into the view and never stamped, which would paint over the bar's rows or the other's (Reference
            # #put_up_background, #stamp_background).
            BAR_SHOWN = "rt scenery bar shown"
            ALONE_SHOWN = "rt scenery alone shown"
            # Whether a scene taking over took the last one's scenery down (Lowering::Scenery#emit_scene_arrival).
            TOOK_DOWN = "rt scenery took down"
            # IN A GAME THAT SHOWS MORE THAN ONE KIND OF SCREEN, the kind up now (Reference @screen_mode,
            # SceneHandover::DISPLAYS): none yet, a painted one, one drawn from tiles, or one that turns. While a painted
            # one is up nothing builds the view (Reference#request_repaint).
            SCREEN_KIND = "rt scenery screen kind"
            NO_SCREEN = 0
            KINDS = { painted: 1, tiles: 2, turning: 3 }.freeze
            PAINTED = KINDS.fetch(:painted)
            # Which row a bend is being worked out for (Lowering::Scenery#emit_bend_rows).
            BEND_ROW = "rt scenery bend row"
            # What a turned background's drawing keeps while it works (#emit_turned_window): the first and third numbers
            # of its turn, how far each pixel moves along the map across and down, and the point of the map at the
            # pivot, across and down.
            TURN_ACROSS = "rt scenery turn across"
            TURN_DOWN = "rt scenery turn down"
            TURN_ORIGIN_X = "rt scenery turn origin x"
            TURN_ORIGIN_Y = "rt scenery turn origin y"

            WORDS = [OWED, EXPIRED, ANY_FROM_CORNER, UP, PLACING, BACKDROP, BUILT, BUILT_BACKDROP, ROW_BEGIN, ROW_END, ROW_OFFSET,
                     TILE_W, MIXED, MASK_DELTA, COLORS_OFFSET, WRAPS, OFF_X,
                     PY, MY, ROUND, SCROLL_SHOWN_X, SCROLL_SHOWN_Y, CLIP_LEFT, CLIP_TOP, CLIP_RIGHT, CLIP_BOTTOM,
                     SCENERY_ROWS, BAR_RECORD, ALONE_ROW, ALONE_RECORD, BAR_SHOWN, ALONE_SHOWN, TOOK_DOWN, SCREEN_KIND, BEND_ROW,
                     TURN_ACROSS, TURN_DOWN, TURN_ORIGIN_X, TURN_ORIGIN_Y].freeze

            module_function

            def field(name) = RECORD.index(name) * 2

            def reserve(memory, backgrounds, held: false, runs: false)
              WORDS.each { |name| memory.reserve(name, 4) }
              RUN_WORDS.each { |name| memory.reserve(name, 4) } if runs
              memory.reserve(STATES, backgrounds * STATE_BYTES)
              return unless held

              [HELD_COUNT, HELD_AT, HELD_KEPT].each { |name| memory.reserve(name, 4) }
              memory.reserve(HELD, HELD_MOST * HELD_BYTES)
            end

            # The place of background number +number+'s STATE.
            def state_at(memory, number) = memory[STATES] + (number * STATE_BYTES)

            # +levels+ is what the view is built from, a level of the stack at a time from the back: the art segment's
            # places of the records of the backgrounds at that level, in the order they are drawn, and whether a sprite
            # can be at that level and is drawn into the view (Sprites::LEVELS). +backgrounds+ is how many there are.
            # +cells+, +held+ and +maps+ say whether the game changes a cell, holds a change for the frame's end, or
            # shows another map. +bars+ is the record of each status bar, and +alone+ each background shown alone above
            # its row, as [its record, its row, whether it keeps the sprites out too]. +live_bends+ is the game's routine
            # that works its bends out as the view is built before its first wait, or nil. +turned+ is each background that
            # can turn, as a Turned. +scene_at+ is where the number of the scene up is kept, in a game with scenes. +crosses+
            # is whether the game shows both kinds of screen.
            def emit(asm, memory, levels:, backgrounds:, cells: false, held: false, maps: false, runs: false, bars: [], alone: [],
                     live_bends: nil, turned: [], scene_at: nil, crosses: false)
              emit_requests(asm, memory, backgrounds, held: held, crosses: crosses)
              emit_paint_run(asm, memory) if runs
              emit_set_cell(asm, memory) if cells
              emit_held(asm, memory) if held
              emit_show_map(asm, memory) if maps
              emit_backdrop(asm, memory)
              emit_view(asm, memory, levels, backgrounds, bars, alone, live_bends, scene_at)
              emit_clipped_window(asm, memory, scene_at)
              emit_wipe(asm, memory)
              turned.each { |background| emit_turned_window(asm, memory, background) }
              emit_fill_rows(asm, memory)
              emit_window(asm, memory, turned)
              emit_stamp(asm, memory)
              emit_map_row(asm, memory)
            end

            def at(memory, name, size = 32) = X86.mem(nil, memory[name], size: size)

            # rt_scenery_request: the view owed. rt_scenery_paint_owed: the view built if it is owed. Either way the
            # corners of a pass that has ended go first (Reference#forget_expired_corners). rt_scenery_frame_ended:
            # the pass that put anything up has ended (Reference#advance_frame). rt_scenery_put_up, with SI at the
            # background's record and BX at its STATE: it shows from its corner, and is stamped.
            # rt_scenery_scroll: EAX and ECX the background's new place, with BX at its STATE.
            #
            # A background put up again shows its cells as they are now, and a change held for it is forgotten
            # (Reference#put_up_background): it was made to the cells the put-up stamps.
            def emit_requests(asm, memory, backgrounds, held: false, crosses: false)
              word = ->(name) { at(memory, name) }
              # rt_scenery_rebuild: the view owed and built again, since what it is built from has changed.
              asm.label("rt_scenery_rebuild")
              asm.mov(word.call(BUILT), 0)
              asm.label("rt_scenery_request")
              if crosses
                asm.cmp(word.call(SCREEN_KIND), PAINTED)
                asm.je("rt_scenery_request_done") # a painted screen is up: it is left as the game paints it
              end
              asm.call("rt_scenery_forget_corners")
              asm.mov(word.call(OWED), 1)
              asm.label("rt_scenery_request_done")
              asm.ret

              asm.label("rt_scenery_paint_owed")
              asm.cmp(word.call(OWED), 0)
              asm.je("rt_scenery_forget_corners")
              asm.mov(word.call(OWED), 0)
              asm.call("rt_scenery_view")

              asm.label("rt_scenery_forget_corners")
              asm.cmp(word.call(EXPIRED), 0)
              asm.je("rt_scenery_corners_kept")
              asm.mov(word.call(EXPIRED), 0)
              asm.mov(word.call(ANY_FROM_CORNER), 0)
              backgrounds.times { |number| asm.mov(X86.mem(nil, state_at(memory, number) + FROM_CORNER, size: 32), 0) }
              asm.label("rt_scenery_corners_kept")
              asm.ret

              asm.label("rt_scenery_frame_ended")
              asm.cmp(word.call(ANY_FROM_CORNER), 0)
              asm.je("rt_scenery_frame_ended_done")
              asm.mov(word.call(EXPIRED), 1)
              asm.label("rt_scenery_frame_ended_done")
              asm.ret

              # rt_scenery_put_up_built: put up, and built into the view rather than stamped, for a status bar and a
              # background held above a row, which a stamp would paint over every row (Reference#put_up_background).
              asm.label("rt_scenery_put_up_built")
              asm.call("rt_scenery_mark_up")
              asm.jmp("rt_scenery_request")
              asm.label("rt_scenery_put_up")
              asm.call("rt_scenery_mark_up")
              # rt_scenery_restamp, with SI at a background's record and BX at its STATE: stamped, or built into the
              # view where a stamp would paint outside the part of the screen it is seen in (Reference#stamp_background).
              asm.label("rt_scenery_restamp")
              asm.cmp(word.call(BAR_SHOWN), 0)
              asm.jne("rt_scenery_request")
              asm.cmp(word.call(ALONE_SHOWN), 0)
              asm.jne("rt_scenery_request")
              asm.cmp(X86.mem(:bx, BOXED, size: 32), 0)
              asm.jne("rt_scenery_request")
              asm.cmp(X86.mem(:bx, TURNED, size: 32), 0) # a stamp would put it back as drawn and lose its turn
              asm.jne("rt_scenery_request")
              asm.jmp("rt_scenery_stamp")
              asm.label("rt_scenery_mark_up")
              if held
                asm.push(:bx)
                asm.call("rt_scenery_forget_held")
                asm.pop(:bx)
              end
              asm.call("rt_scenery_forget_corners")
              asm.mov(X86.mem(:bx, FROM_CORNER, size: 32), 1)
              asm.mov(X86.mem(:bx, SHOWN, size: 32), 1)
              asm.mov(word.call(ANY_FROM_CORNER), 1)
              asm.mov(word.call(UP), 1)
              asm.mov(word.call(BUILT), 0)
              asm.ret

              asm.label("rt_scenery_scroll")
              asm.mov(X86.mem(:bx, SCROLL_X, size: 32), :eax)
              asm.mov(X86.mem(:bx, SCROLL_Y, size: 32), :ecx)
              # A scroll written as the pass ends, where the console places it, leaves a background put up in
              # that pass showing from its corner.
              asm.cmp(word.call(PLACING), 0)
              asm.jne("rt_scenery_request")
              asm.mov(X86.mem(:bx, FROM_CORNER, size: 32), 0)
              asm.jmp("rt_scenery_request")
            end

            # rt_scenery_set_cell, with SI at a background's record: the cell in column EAX and row ECX given the tile
            # whose pixels are at DX (NO_TILE for none), where the map has that cell (Reference#change_cell). A
            # change makes the view owed and built again, since the picture last built does not show it; a cell
            # given the tile it has changes nothing.
            #
            # Two tiles drawn with nothing but see-through pixels are both NO_TILE here, so one put in place of the
            # other changes nothing, where the interpreter changes its map and owes the view. The two views are the
            # same picture, and the interpreter builds the view again at the pass's end anyway in a game that
            # changes cells (Reference @repaints).
            def emit_set_cell(asm, memory)
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_set_cell")
              asm.push(:gs)
              asm.mov_segment(:bx, :art)
              asm.mov(:gs, :bx)
              asm.movzx(:ebx, record.call(:rows))
              asm.cmp(:ecx, :ebx)
              asm.jae("rt_scenery_set_cell_done") # with no sign: a row below nought is past them too
              asm.mov(:bx, record.call(:lengths))
              asm.add(:bx, :cx)
              asm.add(:bx, :cx)
              asm.movzx(:ebx, X86.mem(:bx, 0, seg: :gs, size: 16))
              asm.cmp(:eax, :ebx)
              asm.jae("rt_scenery_set_cell_done")
              asm.movzx(:ebx, record.call(:cols))
              asm.imul(:ebx, :ecx)
              asm.add(:ebx, :eax)
              asm.add(:bx, :bx)
              asm.add(:bx, record.call(:cells))
              asm.cmp(X86.mem(:bx, 0, seg: :gs, size: 16), :dx)
              asm.je("rt_scenery_set_cell_done")
              asm.mov(X86.mem(:bx, 0, seg: :gs, size: 16), :dx)
              asm.pop(:gs)
              asm.mov(at(memory, BUILT), 0)
              asm.jmp("rt_scenery_request")
              asm.label("rt_scenery_set_cell_done")
              asm.pop(:gs)
              asm.ret
            end

            # rt_scenery_hold_cell: what rt_scenery_set_cell is handed, held for rt_scenery_show_held, with every change
            # waiting put in first where HELD_MOST are. rt_scenery_show_held: every change waiting, in order.
            # rt_scenery_forget_held, with SI at a background's record: the changes waiting for it let go, the
            # others kept in their order. Changes EAX, EDX and BX.
            def emit_held(asm, memory)
              count = at(memory, HELD_COUNT, 16)
              entry = ->(part) { X86.mem(:bx, part, size: 16) }
              asm.label("rt_scenery_hold_cell")
              asm.cmp(count, HELD_MOST)
              asm.jb("rt_scenery_hold_room")
              [:eax, :ecx, :edx, :si].each { |register| asm.push(register) }
              asm.call("rt_scenery_show_held")
              [:si, :edx, :ecx, :eax].each { |register| asm.pop(register) }
              asm.label("rt_scenery_hold_room")
              %i[eax ecx].each do |register|
                asm.cmp(register, 0xFFFF)
                asm.jb("rt_scenery_hold_#{register}_kept")
                asm.mov(register, 0xFFFF)
                asm.label("rt_scenery_hold_#{register}_kept")
              end
              asm.mov(:bx, count)
              asm.shl(:bx, 3)
              asm.add(:bx, memory[HELD])
              asm.mov(entry.call(0), :si)
              asm.mov(entry.call(2), :dx)
              asm.mov(entry.call(4), :ax)
              asm.mov(entry.call(6), :cx)
              asm.inc(count)
              asm.ret

              asm.label("rt_scenery_show_held")
              asm.mov(at(memory, HELD_AT, 16), 0)
              asm.label("rt_scenery_show_held_next")
              asm.mov(:bx, at(memory, HELD_AT, 16))
              asm.cmp(:bx, count)
              asm.jae("rt_scenery_show_held_done")
              asm.shl(:bx, 3)
              asm.add(:bx, memory[HELD])
              asm.mov(:si, entry.call(0))
              asm.mov(:dx, entry.call(2))
              asm.movzx(:eax, entry.call(4))
              asm.movzx(:ecx, entry.call(6))
              asm.call("rt_scenery_set_cell")
              asm.inc(at(memory, HELD_AT, 16))
              asm.jmp("rt_scenery_show_held_next")
              asm.label("rt_scenery_show_held_done")
              asm.mov(count, 0)
              asm.ret

              asm.label("rt_scenery_forget_held")
              asm.mov(at(memory, HELD_AT, 16), 0)
              asm.mov(at(memory, HELD_KEPT, 16), 0)
              asm.label("rt_scenery_forget_held_next")
              asm.mov(:bx, at(memory, HELD_AT, 16))
              asm.cmp(:bx, count)
              asm.jae("rt_scenery_forget_held_done")
              asm.inc(at(memory, HELD_AT, 16))
              asm.shl(:bx, 3)
              asm.add(:bx, memory[HELD])
              asm.cmp(entry.call(0), :si)
              asm.je("rt_scenery_forget_held_next")
              asm.mov(:eax, X86.mem(:bx, 0, size: 32))
              asm.mov(:edx, X86.mem(:bx, 4, size: 32))
              asm.mov(:bx, at(memory, HELD_KEPT, 16))
              asm.inc(at(memory, HELD_KEPT, 16))
              asm.shl(:bx, 3)
              asm.add(:bx, memory[HELD])
              asm.mov(X86.mem(:bx, 0, size: 32), :eax)
              asm.mov(X86.mem(:bx, 4, size: 32), :edx)
              asm.jmp("rt_scenery_forget_held_next")
              asm.label("rt_scenery_forget_held_done")
              asm.mov(:ax, at(memory, HELD_KEPT, 16))
              asm.mov(count, :ax)
              asm.ret
            end

            # rt_scenery_show_map, with SI at a background's record: its map number EAX copied into its cells as
            # declared, every change made to them gone, and the view owed (Reference#exec_show_map). A number that
            # names none of its maps changes nothing.
            def emit_show_map(asm, memory)
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_show_map")
              asm.push(:gs)
              asm.mov_segment(:bx, :art)
              asm.mov(:gs, :bx)
              asm.movzx(:ebx, record.call(:map_count))
              asm.cmp(:eax, :ebx)
              asm.jae("rt_scenery_show_map_done")
              asm.shl(:ax, 2)
              asm.mov(:bx, record.call(:maps))
              asm.add(:bx, :ax)
              [:si, :di, :bp, :ds, :es].each { |register| asm.push(register) }
              asm.mov(:ax, X86.mem(:bx, 2, seg: :gs, size: 16))
              asm.mov(record.call(:lengths), :ax)
              asm.mov(:dx, record.call(:cols))
              asm.mov(:bp, record.call(:rows))
              asm.mov(:di, record.call(:cells))
              asm.mov(:si, X86.mem(:bx, 0, seg: :gs, size: 16))
              asm.mov(:bx, :ax) # each row's length, from here on
              asm.push(:gs)
              asm.pop(:ds)
              asm.push(:gs)
              asm.pop(:es)
              asm.test(:bp, :bp)
              asm.je("rt_scenery_show_map_laid") # a map of no rows has nothing to lay
              asm.label("rt_scenery_show_map_row")
              asm.mov(:cx, X86.mem(:bx, 0, size: 16))
              asm.add(:bx, 2)
              asm.mov(:ax, :dx)
              asm.sub(:ax, :cx)
              asm.movs(16, rep: true)
              asm.mov(:cx, :ax)
              asm.mov(:ax, NO_TILE)
              asm.stos(16, rep: true)
              asm.dec(:bp)
              asm.jne("rt_scenery_show_map_row")
              asm.label("rt_scenery_show_map_laid")
              [:es, :ds, :bp, :di, :si].each { |register| asm.pop(register) }
              asm.pop(:gs)
              asm.mov(at(memory, BUILT), 0)
              asm.jmp("rt_scenery_request")
              asm.label("rt_scenery_show_map_done")
              asm.pop(:gs)
              asm.ret
            end

            # rt_scenery_paint_run, with BX at a list and SI at a run's header in the art segment: every tile of a
            # background the run paints laid out from what the list holds now, each pixel its colour, or nought
            # with its mask set where its place is nought, the see-through one (Reference#copy_run_tiles). A byte
            # past the list's last item is nought, which is all see-through. Keeps BP.
            def emit_paint_run(asm, memory)
              word = ->(name) { at(memory, "rt scenery run #{name}", 16) }
              list = ->(part) { X86.mem(:bx, part, size: 16) }
              header = ->(part) { X86.mem(:bx, part, seg: :gs, size: 16) }
              asm.label("rt_scenery_paint_run")
              asm.push(:gs)
              asm.mov_segment(:ax, :art)
              asm.mov(:gs, :ax)
              asm.mov(word.call("list"), :bx)
              asm.mov(word.call("header"), :si)
              asm.mov(:ax, X86.mem(:si, RUN_COUNT, seg: :gs, size: 16))
              asm.mov(word.call("left"), :ax)
              asm.add(:si, RUN_HEADER)
              asm.mov(word.call("entry"), :si)
              asm.label("rt_scenery_run_tile")
              asm.cmp(word.call("left"), 0)
              asm.je("rt_scenery_run_done")
              asm.dec(word.call("left"))
              asm.mov(:si, word.call("entry"))
              asm.add(word.call("entry"), RUN_ENTRY_BYTES)
              %w[item pixels mask].each_with_index do |name, i|
                asm.mov(:ax, X86.mem(:si, i * 2, seg: :gs, size: 16))
                asm.mov(word.call(name), :ax)
              end
              asm.mov(word.call("byte"), 0)

              asm.label("rt_scenery_run_byte")
              asm.mov(:bx, word.call("list"))
              asm.movzx(:eax, word.call("item"))
              asm.movzx(:ecx, word.call("byte"))
              asm.add(:eax, :ecx)
              asm.movzx(:ecx, list.call(Lists::LENGTH))
              asm.cmp(:eax, :ecx)
              asm.jae("rt_scenery_run_past")
              asm.add(:ax, list.call(Lists::FRONT))
              asm.cmp(:ax, list.call(Lists::CAPACITY))
              asm.jb("rt_scenery_run_within")
              asm.sub(:ax, list.call(Lists::CAPACITY)) # once round the ring
              asm.label("rt_scenery_run_within")
              asm.mov(:cl, X86.mem(:bx, Lists::SHIFT, size: 8))
              asm.shl(:ax, :cl)
              asm.mov(:si, :ax)
              asm.mov(:al, X86.mem(:bx, Lists::HEADER, index: :si, size: 8)) # the slot's low byte
              asm.jmp("rt_scenery_run_read")
              asm.label("rt_scenery_run_past")
              asm.xor(:al, :al)
              asm.label("rt_scenery_run_read")
              asm.mov(:bx, word.call("header"))
              asm.mov(:si, header.call(RUN_PLACES))
              asm.add(:si, word.call("byte"))
              asm.add(:si, word.call("byte"))
              asm.mov(:di, X86.mem(:si, 0, seg: :gs, size: 16))
              asm.add(:di, word.call("pixels"))
              asm.mov(:dl, :al)
              asm.and(:dl, 0x0F) # the left pixel's place
              asm.call("rt_scenery_run_pixel")
              asm.inc(:di)
              asm.mov(:dl, :al)
              asm.shr(:dl, 4)
              asm.call("rt_scenery_run_pixel")
              asm.inc(word.call("byte"))
              asm.mov(:ax, word.call("byte"))
              asm.cmp(:ax, header.call(RUN_TILE_BYTES))
              asm.jb("rt_scenery_run_byte")
              asm.jmp("rt_scenery_run_tile")
              asm.label("rt_scenery_run_done")
              asm.pop(:gs)
              asm.ret

              # The pixel at DI given place DL of the run's colours, with BX at the run's header. Keeps AL and DI.
              asm.label("rt_scenery_run_pixel")
              asm.mov(:si, :di)
              asm.add(:si, word.call("mask"))
              asm.test(:dl, :dl)
              asm.je("rt_scenery_run_see_through")
              asm.push(:bx)
              asm.mov(:bx, header.call(RUN_COLORS))
              asm.movzx(:cx, :dl)
              asm.add(:bx, :cx)
              asm.mov(:dl, X86.mem(:bx, 0, seg: :gs, size: 8))
              asm.pop(:bx)
              asm.mov(X86.mem(:di, 0, seg: :gs, size: 8), :dl)
              asm.mov(X86.mem(:si, 0, seg: :gs, size: 8), 0)
              asm.ret
              asm.label("rt_scenery_run_see_through")
              asm.mov(X86.mem(:di, 0, seg: :gs, size: 8), 0)
              asm.mov(X86.mem(:si, 0, seg: :gs, size: 8), 0xFF)
              asm.ret
            end

            # rt_scenery_backdrop: AL the palette entry shown wherever nothing is drawn (Reference#show_backdrop).
            # The same one changes nothing; another builds the view again where anything is up, and otherwise
            # fills the picture with it.
            def emit_backdrop(asm, memory)
              backdrop = at(memory, BACKDROP, 8)
              asm.label("rt_scenery_backdrop")
              asm.cmp(:al, backdrop)
              asm.je("rt_scenery_backdrop_done")
              asm.mov(backdrop, :al)
              asm.cmp(at(memory, UP), 0)
              asm.jne("rt_scenery_request")
              asm.mov(at(memory, BUILT), 0)
              emit_fill_with_backdrop(asm, memory, "rt_scenery_backdrop")
              asm.label("rt_scenery_backdrop_done")
              asm.ret
            end

            # The picture filled with the backdrop's entry, four to EAX, every row marked as changed.
            def emit_fill_with_backdrop(asm, memory, tag)
              asm.movzx(:eax, at(memory, BACKDROP, 8))
              asm.mov(:ah, :al)
              asm.mov(:cx, :ax)
              asm.shl(:eax, 16)
              asm.mov(:ax, :cx)
              Rows.emit_fill_picture(asm, memory.screen, tag)
              Runtime.emit_mark_every_row(asm, memory)
            end

            # rt_scenery_view: the whole view built again (Reference#repaint_view): the backdrop, then a level of
            # the stack at a time from the back, each background's window at that level and then, in a game that
            # draws its sprites at their levels, the sprites placed there (rt_sprites_at_level).
            #
            # The interpreter builds it every pass in a game that scrolls. What it builds depends on nothing but the
            # backdrop and where each background shows from, so where the picture is still the view last built
            # (BUILT) and none of those has changed, building it again would make the same picture, and is left.
            # Placing sprites that are drawn into the view builds it again (rt_scenery_rebuild).
            def emit_view(asm, memory, levels, backgrounds, bars, alone, live_bends, scene_at = nil)
              asm.label("rt_scenery_view")
              asm.cmp(at(memory, BUILT), 0)
              asm.je("rt_scenery_view_build")
              asm.mov(:al, at(memory, BACKDROP, 8))
              asm.cmp(:al, at(memory, BUILT_BACKDROP, 8))
              asm.jne("rt_scenery_view_build")
              backgrounds.times do |number|
                state = ->(part) { X86.mem(nil, state_at(memory, number) + part, size: 32) }
                kept = "rt_scenery_view_#{number}_kept"
                asm.xor(:eax, :eax)
                asm.xor(:ecx, :ecx)
                asm.cmp(state.call(FROM_CORNER), 0)
                asm.jne("rt_scenery_view_#{number}_shown")
                asm.mov(:eax, state.call(SCROLL_X))
                asm.mov(:ecx, state.call(SCROLL_Y))
                asm.label("rt_scenery_view_#{number}_shown")
                asm.cmp(:eax, state.call(BUILT_X))
                asm.jne("rt_scenery_view_build")
                asm.cmp(:ecx, state.call(BUILT_Y))
                asm.je(kept)
                asm.jmp("rt_scenery_view_build")
                asm.label(kept)
              end
              asm.ret
              asm.label("rt_scenery_view_build")
              if live_bends
                # Before the first wait the bends have not been worked out, and the interpreter asks each row as it
                # builds the view (Reference#bend_offset_at).
                asm.cmp(X86.mem(nil, memory[Frame::PASSES], size: 32), 0)
                asm.jne("rt_scenery_view_bends_kept")
                asm.call(live_bends)
                asm.label("rt_scenery_view_bends_kept")
              end
              asm.mov(at(memory, BUILT), 1)
              asm.mov(:al, at(memory, BACKDROP, 8))
              asm.mov(at(memory, BUILT_BACKDROP, 8), :al)
              emit_fill_with_backdrop(asm, memory, "rt_scenery_view")
              asm.push(:gs)
              asm.mov_segment(:ax, :art)
              asm.mov(:gs, :ax)
              emit_view_bar(asm, memory, bars, scene_at)
              emit_view_alone(asm, memory, alone, scene_at)
              levels.each_with_index do |(records, sprites), level|
                records.each do |record|
                  asm.mov(:si, record)
                  asm.call("rt_scenery_clipped_window")
                end
                next unless sprites

                asm.mov(:al, level)
                asm.call("rt_sprites_at_level")
              end
              emit_view_over_sprites(asm, memory, bars, alone, scene_at)
              asm.pop(:gs)
              asm.ret
            end

            # To +label+ unless the background whose record SI is at (GS at the art) is showing: one every screen shows,
            # or a scene's own while that scene is up (SceneHandover#showing), whether or not it has been put up yet, as
            # the interpreter paints it. Changes EAX.
            def emit_unless_showing(asm, scene_at, label)
              return unless scene_at

              showing = "#{label}_showing"
              asm.movzx(:eax, X86.mem(:si, field(:scene), seg: :gs, size: 16))
              asm.test(:eax, :eax)
              asm.je(showing)
              asm.dec(:eax)
              asm.cmp(:eax, X86.mem(nil, scene_at, size: 32))
              asm.jne(label)
              asm.label(showing)
            end

            # rt_scenery_wipe: the picture the backdrop again, every row marked, and no longer the view as built, as a
            # scene taking over takes the last one's scenery down (Reference#take_down_scenery).
            def emit_wipe(asm, memory)
              asm.label("rt_scenery_wipe")
              asm.mov(at(memory, BUILT), 0)
              emit_fill_with_backdrop(asm, memory, "rt_scenery_wipe")
              asm.ret
            end

            # The clip set to the whole width, from row +top+ (a register, or a number) to +bottom+.
            def emit_clip_rows(asm, memory, top, bottom)
              asm.mov(at(memory, CLIP_LEFT), 0)
              asm.mov(at(memory, CLIP_RIGHT), memory.screen.width)
              asm.mov(at(memory, CLIP_TOP), top)
              asm.mov(at(memory, CLIP_BOTTOM), bottom)
            end

            # A status bar first (Reference#repaint_view): the one showing, from its top to the screen's bottom, and
            # the rows above its top are where the backgrounds are seen. Its top is where it was declared while it
            # shows from its corner, and where it was last placed after.
            def emit_view_bar(asm, memory, bars, scene_at = nil)
              asm.mov(at(memory, SCENERY_ROWS), memory.screen.height)
              asm.mov(at(memory, BAR_RECORD, 16), 0)
              bars.each_with_index do |record, nth|
                down = "rt_scenery_view_bar_#{nth}_down"
                asm.mov(:si, record)
                asm.mov(:bx, X86.mem(:si, field(:state), seg: :gs, size: 16))
                emit_unless_showing(asm, scene_at, down)
                emit_bar_top(asm, "rt_scenery_view_bar_#{nth}")
                asm.mov(at(memory, SCENERY_ROWS), :eax)
                asm.mov(at(memory, BAR_RECORD, 16), :si)
                emit_clip_rows(asm, memory, :eax, memory.screen.height)
                asm.call("rt_scenery_window")
                asm.label(down)
              end
            end

            # EAX the top of the status bar whose record SI is at and whose STATE BX is at, as shown now.
            def emit_bar_top(asm, tag)
              asm.movsx(:eax, X86.mem(:si, field(:corner_y), seg: :gs, size: 16))
              asm.cmp(X86.mem(:bx, FROM_CORNER, size: 32), 0)
              asm.jne("#{tag}_top")
              asm.mov(:eax, X86.mem(:bx, SCROLL_Y, size: 32))
              asm.label("#{tag}_top")
              asm.neg(:eax)
            end

            # The row of a background shown alone above its row, if one is up: the others are seen only below it.
            def emit_view_alone(asm, memory, alone, scene_at = nil)
              asm.mov(at(memory, ALONE_ROW), 0)
              alone.each_with_index do |(record, row, _without_sprites), nth|
                down = "rt_scenery_view_alone_#{nth}_down"
                asm.mov(:si, record)
                emit_unless_showing(asm, scene_at, down)
                asm.cmp(at(memory, ALONE_ROW), 0)
                asm.jne(down) # the first one up, as the interpreter finds it
                asm.mov(at(memory, ALONE_ROW), row)
                asm.mov(at(memory, ALONE_RECORD, 16), record)
                asm.label(down)
              end
            end

            # Over the sprites drawn into the view: a status bar that covers them, its rows from the backdrop up again
            # (Reference#paint_bar_over_sprites), and a background shown alone without them, its rows above its row
            # (Reference#paint_held_over_sprites).
            def emit_view_over_sprites(asm, memory, bars, alone, scene_at = nil)
              unless bars.empty?
                asm.mov(:si, at(memory, BAR_RECORD, 16))
                asm.test(:si, :si)
                asm.je("rt_scenery_view_uncovered")
                asm.mov(:bx, X86.mem(:si, field(:state), seg: :gs, size: 16))
                asm.cmp(X86.mem(:bx, COVERS, size: 32), 0)
                asm.je("rt_scenery_view_uncovered")
                asm.mov(:eax, at(memory, SCENERY_ROWS))
                emit_clip_rows(asm, memory, :eax, memory.screen.height)
                asm.call("rt_scenery_fill_rows")
                asm.call("rt_scenery_window")
                asm.label("rt_scenery_view_uncovered")
              end
              alone.each_with_index do |(record, row, without_sprites), nth|
                next unless without_sprites

                down = "rt_scenery_view_held_#{nth}_down"
                asm.mov(:si, record)
                emit_unless_showing(asm, scene_at, down)
                asm.mov(:eax, at(memory, SCENERY_ROWS))
                asm.cmp(:eax, row)
                asm.jle("rt_scenery_view_held_#{nth}_rows")
                asm.mov(:eax, row)
                asm.label("rt_scenery_view_held_#{nth}_rows")
                emit_clip_rows(asm, memory, 0, :eax)
                asm.call("rt_scenery_fill_rows")
                asm.call("rt_scenery_clipped_window") # in the rows it is seen in, and inside its box
                asm.label(down)
              end
            end

            # rt_scenery_fill_rows: the rows of the clip, CLIP_TOP to CLIP_BOTTOM, filled with the backdrop. Keeps SI
            # and BX.
            def emit_fill_rows(asm, memory)
              asm.label("rt_scenery_fill_rows")
              asm.push(:ebp)
              asm.mov(:ebp, at(memory, CLIP_TOP))
              asm.label("rt_scenery_fill_rows_row")
              asm.cmp(:ebp, at(memory, CLIP_BOTTOM))
              asm.jge("rt_scenery_fill_rows_done")
              Rows.emit_row_start(asm, memory.screen, :ebp)
              asm.movzx(:eax, at(memory, BACKDROP, 8))
              asm.mov(:ah, :al)
              asm.mov(:cx, :ax)
              asm.shl(:eax, 16)
              asm.mov(:ax, :cx)
              asm.mov(:cx, memory.screen.width / 4)
              asm.stos(32, rep: true)
              asm.inc(:ebp)
              asm.jmp("rt_scenery_fill_rows_row")
              asm.label("rt_scenery_fill_rows_done")
              asm.pop(:ebp)
              asm.ret
            end

            # rt_scenery_clipped_window, with SI at a background's record and GS at the art: its window painted in the
            # part of the screen it is seen in (CLIP_LEFT and the rest), or not at all where that is nothing: the rows
            # above a status bar's top, and above its own row where it is held above one; below the row of another
            # shown alone above its row; and inside its box, where it is held to one.
            def emit_clipped_window(asm, memory, scene_at = nil)
              clip = ->(name) { at(memory, name) }
              asm.label("rt_scenery_clipped_window")
              emit_unless_showing(asm, scene_at, "rt_scenery_clipped_nothing")
              asm.mov(:bx, X86.mem(:si, field(:state), seg: :gs, size: 16))
              asm.mov(:eax, clip.call(SCENERY_ROWS))
              emit_clip_rows(asm, memory, 0, :eax)
              asm.movzx(:eax, X86.mem(:si, field(:above_row), seg: :gs, size: 16))
              asm.test(:eax, :eax)
              asm.je("rt_scenery_clipped_no_row")
              # A background that has turned is drawn on every row the backgrounds are seen in, its own row or not,
              # as the interpreter draws it (Reference#paint_affine_background_window).
              asm.cmp(X86.mem(:bx, TURNED, size: 32), 0)
              asm.jne("rt_scenery_clipped_no_row")
              asm.cmp(:eax, clip.call(CLIP_BOTTOM))
              asm.jge("rt_scenery_clipped_no_row")
              asm.mov(clip.call(CLIP_BOTTOM), :eax)
              asm.label("rt_scenery_clipped_no_row")
              asm.mov(:eax, clip.call(ALONE_ROW))
              asm.test(:eax, :eax)
              asm.je("rt_scenery_clipped_not_alone")
              asm.cmp(:si, at(memory, ALONE_RECORD, 16))
              asm.je("rt_scenery_clipped_not_alone")
              asm.mov(clip.call(CLIP_TOP), :eax)
              asm.label("rt_scenery_clipped_not_alone")
              asm.cmp(X86.mem(:bx, BOXED, size: 32), 0)
              asm.je("rt_scenery_clipped_unboxed")
              { BOX_LEFT => CLIP_LEFT, BOX_TOP => CLIP_TOP }.each do |side, name| # the box's start, where it is further in
                asm.mov(:eax, X86.mem(:bx, side, size: 32))
                asm.cmp(:eax, clip.call(name))
                asm.jle("rt_scenery_clipped_#{side}_kept")
                asm.mov(clip.call(name), :eax)
                asm.label("rt_scenery_clipped_#{side}_kept")
              end
              { BOX_RIGHT => CLIP_RIGHT, BOX_BOTTOM => CLIP_BOTTOM }.each do |side, name| # and its end, where it is nearer
                asm.mov(:eax, X86.mem(:bx, side, size: 32))
                asm.cmp(:eax, clip.call(name))
                asm.jge("rt_scenery_clipped_#{side}_kept")
                asm.mov(clip.call(name), :eax)
                asm.label("rt_scenery_clipped_#{side}_kept")
              end
              asm.label("rt_scenery_clipped_unboxed")
              asm.mov(:eax, clip.call(CLIP_RIGHT))
              asm.cmp(:eax, clip.call(CLIP_LEFT))
              asm.jle("rt_scenery_clipped_nothing")
              asm.mov(:eax, clip.call(CLIP_BOTTOM))
              asm.cmp(:eax, clip.call(CLIP_TOP))
              asm.jg("rt_scenery_window")
              asm.label("rt_scenery_clipped_nothing")
              asm.ret
            end

            # rt_scenery_window, with SI at a background's record and GS at the art: its window painted where it is
            # scrolled to, or from its corner (Reference#paint_background_window, #paint_streamed_background_window).
            def emit_window(asm, memory, turned = [])
              word = ->(name) { at(memory, name) }
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_window")
              asm.mov(:bx, record.call(:state))
              turned.each do |background|
                asm.cmp(:si, background.record)
                asm.jne("rt_scenery_window_not_#{background.record}")
                asm.cmp(X86.mem(:bx, TURNED, size: 32), 0)
                asm.jne(turned_label(background))
                asm.label("rt_scenery_window_not_#{background.record}")
              end
              asm.xor(:eax, :eax)
              asm.movsx(:ecx, record.call(:corner_y))
              asm.cmp(X86.mem(:bx, FROM_CORNER, size: 32), 0)
              asm.jne("rt_scenery_window_placed")
              asm.mov(:eax, X86.mem(:bx, SCROLL_X, size: 32))
              asm.mov(:ecx, X86.mem(:bx, SCROLL_Y, size: 32))
              asm.label("rt_scenery_window_placed")
              asm.mov(X86.mem(:bx, BUILT_X, size: 32), :eax)
              asm.mov(X86.mem(:bx, BUILT_Y, size: 32), :ecx)
              asm.mov(word.call(SCROLL_SHOWN_X), :eax)
              asm.mov(word.call(SCROLL_SHOWN_Y), :ecx)
              asm.mov(:eax, word.call(CLIP_TOP))
              asm.mov(word.call(PY), :eax)
              asm.cmp(:eax, word.call(CLIP_BOTTOM))
              asm.jge("rt_scenery_window_no_rows") # a bar at the screen's bottom, or a background left no rows
              asm.cmp(record.call(:wrap_w), 0)
              asm.jne("rt_scenery_window_wraps")

              # A map that does not come round: a row above or below it shows what is behind.
              asm.label("rt_scenery_window_row")
              asm.mov(:eax, word.call(SCROLL_SHOWN_Y))
              asm.add(:eax, word.call(PY))
              asm.jo("rt_scenery_window_row_done")
              asm.test(:eax, :eax)
              asm.js("rt_scenery_window_row_done")
              asm.movzx(:ebx, record.call(:map_h))
              asm.cmp(:eax, :ebx)
              asm.jge("rt_scenery_window_row_done")
              asm.mov(:ecx, word.call(SCROLL_SHOWN_X))
              asm.movzx(:ebx, record.call(:bends))
              asm.test(:ebx, :ebx)
              asm.je("rt_scenery_window_row_flat")
              asm.mov(:edx, word.call(PY))
              asm.shl(:edx, 2)
              asm.add(:bx, :dx)
              asm.add(:ecx, X86.mem(:bx, 0, size: 32)) # the row moved along by its bend (Reference#bend_offset_at)
              asm.jo("rt_scenery_window_row_done") # so far along that none of the map is on the row
              asm.label("rt_scenery_window_row_flat")
              asm.xor(:edx, :edx)
              emit_map_row_call(asm, memory)
              asm.label("rt_scenery_window_row_done")
              emit_next_py(asm, memory, "rt_scenery_window_row")
              asm.ret

              # A map that comes round at its grid's edge: the window's corner brought inside the grid first.
              asm.label("rt_scenery_window_wraps")
              { SCROLL_SHOWN_X => :wrap_w, SCROLL_SHOWN_Y => :wrap_h }.each do |name, side|
                asm.mov(:eax, word.call(name))
                asm.movzx(:ebx, record.call(side))
                asm.cdq
                asm.idiv(:ebx)
                asm.test(:edx, :edx)
                asm.jns("rt_scenery_#{side}_kept")
                asm.add(:edx, :ebx)
                asm.label("rt_scenery_#{side}_kept")
                asm.mov(word.call(name), :edx)
              end
              asm.label("rt_scenery_window_wrapped_row")
              asm.mov(:eax, word.call(SCROLL_SHOWN_Y))
              asm.add(:eax, word.call(PY))
              asm.movzx(:ebx, record.call(:wrap_h))
              asm.label("rt_scenery_window_bring_round")
              asm.cmp(:eax, :ebx)
              asm.jl("rt_scenery_window_brought_round")
              asm.sub(:eax, :ebx)
              asm.jmp("rt_scenery_window_bring_round")
              asm.label("rt_scenery_window_brought_round")
              asm.mov(:ecx, word.call(SCROLL_SHOWN_X))
              asm.movzx(:edx, record.call(:wrap_w))
              emit_wrapped_bend(asm, memory, record)
              emit_map_row_call(asm, memory)
              emit_next_py(asm, memory, "rt_scenery_window_wrapped_row")
              asm.label("rt_scenery_window_no_rows")
              asm.ret
            end

            # A background that can turn, as the drawing of it is written: its record's place, and its tiles' width and
            # height, its grid's columns and rows (each a power of two, so a place on the map comes round by a mask),
            # where its cells are, where its tiles with see-through pixels start and how far past them a mask is.
            Turned = Data.define(:record, :tile_w, :tile_h, :cols, :rows, :cells, :mixed, :mask_delta)

            def turned_label(background) = "rt_scenery_turned_#{background.record}"

            # The window of a background that has turned, with SI at its record and BX at its STATE: each pixel of the
            # rows and columns of the clip worked back through its turn to the pixel of the map it shows, the map
            # coming round at its grid's edge, and a see-through pixel or a cell with no tile leaving what is there
            # (Reference#paint_affine_background_window).
            #
            # Along a row a pixel's place on the map moves by the turn's first number across and its third down, in
            # 256ths, so a pixel costs two additions and the masks: the sum before the shift is kept whole, so the
            # 256th dropped is the one the interpreter drops for that pixel. While the row is drawn DS is the art.
            def emit_turned_window(asm, memory, background)
              tag = turned_label(background)
              kept = ->(name) { X86.mem(nil, memory[name], seg: :ss, size: 32) }
              state = ->(part) { X86.mem(:bx, part, size: 32) }
              tile_shift = background.tile_w.bit_length - 1
              row_shift = background.tile_h.bit_length - 1
              col_shift = background.cols.bit_length - 1
              asm.label(tag)
              asm.mov(:eax, state.call(ANGLE))
              asm.mov(:ecx, state.call(SIZE))
              asm.push(:si)
              asm.push(:bx)
              asm.call("rt_turn_matrix")
              asm.pop(:bx)
              asm.pop(:si)
              asm.mov(at(memory, TURN_ACROSS), :eax) # the first number: across the map for a pixel across
              asm.neg(:edx)
              asm.mov(at(memory, TURN_DOWN), :edx) # the third: down the map for a pixel across
              # The point of the map at the pivot: the scroll the turn set, plus the pivot, brought inside the map, which
              # comes round by a power of two, and in 256ths, so a row's sums start from it and a pixel adds nothing.
              { x: background.cols * background.tile_w, y: background.rows * background.tile_h }.each do |axis, side|
                asm.mov(:eax, state.call(axis == :x ? SCROLL_X : SCROLL_Y))
                asm.add(:eax, state.call(axis == :x ? PIVOT_X : PIVOT_Y))
                asm.and(:eax, side - 1)
                asm.shl(:eax, 8)
                asm.mov(at(memory, axis == :x ? TURN_ORIGIN_X : TURN_ORIGIN_Y), :eax)
              end
              asm.mov(:ax, X86.mem(:si, field(:colors_offset), seg: :gs, size: 16))
              asm.mov(at(memory, COLORS_OFFSET, 16), :ax)
              asm.mov(:eax, at(memory, CLIP_TOP))
              asm.mov(at(memory, PY), :eax)
              asm.cmp(:eax, at(memory, CLIP_BOTTOM))
              asm.jge("#{tag}_done")
              asm.label("#{tag}_row")
              # The row's first pixel's place on the map, in 256ths from the pivot's (Affine.matrix's four numbers are
              # the first, less than nought the third, the third and the first): across, the first times how far it is
              # across from the pivot and the second times how far down; down, the third and the fourth the same.
              asm.mov(:ebp, at(memory, PY))
              asm.sub(:ebp, state.call(PIVOT_Y)) # down from the pivot
              asm.mov(:ecx, at(memory, CLIP_LEFT))
              asm.sub(:ecx, state.call(PIVOT_X)) # across from it
              asm.mov(:eax, at(memory, TURN_ACROSS))
              asm.imul(:eax, :ecx)
              asm.mov(:edx, at(memory, TURN_DOWN))
              asm.imul(:edx, :ebp)
              asm.sub(:eax, :edx)
              asm.add(:eax, at(memory, TURN_ORIGIN_X))
              asm.mov(at(memory, ROW_BEGIN), :eax) # across the map, before the shift
              asm.mov(:eax, at(memory, TURN_DOWN))
              asm.imul(:eax, :ecx)
              asm.mov(:edx, at(memory, TURN_ACROSS))
              asm.imul(:edx, :ebp)
              asm.add(:eax, :edx)
              asm.add(:eax, at(memory, TURN_ORIGIN_Y))
              asm.mov(at(memory, ROW_END), :eax) # down the map, before the shift
              asm.push(:bx)
              asm.push(:si)
              asm.mov(:ebp, at(memory, PY))
              Rows.emit_row_start(asm, memory.screen, :ebp)
              asm.mov(:ax, :di)
              asm.add(:di, at(memory, CLIP_LEFT, 16))
              asm.add(:ax, at(memory, CLIP_RIGHT, 16))
              asm.mov(at(memory, OFF_X, 16), :ax) # where the row's last pixel is passed
              asm.mov(:ebp, at(memory, ROW_BEGIN))
              asm.mov(:edx, at(memory, ROW_END))
              asm.push(:ds)
              asm.push(:gs)
              asm.pop(:ds)
              asm.label("#{tag}_pixel")
              asm.mov(:eax, :ebp)
              asm.sar(:eax, 8)
              asm.and(:eax, (background.cols * background.tile_w) - 1) # across the map, come round
              asm.mov(:ebx, :edx)
              asm.sar(:ebx, 8)
              asm.and(:ebx, (background.rows * background.tile_h) - 1) # and down
              asm.mov(:esi, :ebx)
              asm.shr(:esi, row_shift)
              asm.shl(:esi, col_shift + 1)
              asm.mov(:ecx, :eax)
              asm.shr(:ecx, tile_shift)
              asm.add(:esi, :ecx)
              asm.add(:esi, :ecx) # a word a cell
              asm.mov(:si, X86.mem(:si, background.cells, size: 16)) # the cell: where its tile's pixels are
              asm.cmp(:si, NO_TILE)
              asm.je("#{tag}_empty")
              asm.and(:ebx, background.tile_h - 1)
              asm.shl(:ebx, tile_shift)
              asm.and(:eax, background.tile_w - 1)
              asm.add(:ebx, :eax)
              asm.add(:bx, :si)
              asm.add(:bx, X86.mem(nil, memory[COLORS_OFFSET], seg: :ss, size: 16))
              asm.cmp(:si, background.mixed)
              asm.jb("#{tag}_solid")
              asm.cmp(X86.mem(:bx, background.mask_delta, size: 8), 0xFF)
              asm.je("#{tag}_empty")
              asm.label("#{tag}_solid")
              asm.mov(:al, X86.mem(:bx, 0, size: 8))
              asm.mov(X86.mem(:di, 0, seg: :es, size: 8), :al)
              asm.label("#{tag}_empty")
              asm.inc(:di)
              asm.add(:ebp, kept.call(TURN_ACROSS))
              asm.add(:edx, kept.call(TURN_DOWN))
              asm.cmp(:di, X86.mem(nil, memory[OFF_X], seg: :ss, size: 16))
              asm.jne("#{tag}_pixel")
              asm.pop(:ds)
              asm.pop(:si)
              asm.pop(:bx)
              asm.mov(:eax, at(memory, PY))
              asm.inc(:eax)
              asm.mov(at(memory, PY), :eax)
              asm.cmp(:eax, at(memory, CLIP_BOTTOM))
              asm.jl("#{tag}_row")
              asm.label("#{tag}_done")
              asm.ret
            end

            # On a map that comes round, ECX (the window's column, inside the grid) moved along by the row's bend and
            # brought round inside the grid again (Reference#paint_background_window); EDX the grid's width before and
            # after. Keeps EAX.
            def emit_wrapped_bend(asm, memory, record)
              asm.movzx(:ebx, record.call(:bends))
              asm.test(:ebx, :ebx)
              asm.je("rt_scenery_window_wrapped_flat")
              asm.push(:eax)
              asm.mov(:eax, at(memory, PY))
              asm.shl(:eax, 2)
              asm.add(:bx, :ax)
              asm.mov(:eax, X86.mem(:bx, 0, size: 32))
              asm.mov(:ebx, :edx)
              asm.cdq
              asm.idiv(:ebx)
              asm.test(:edx, :edx)
              asm.jns("rt_scenery_window_bend_kept")
              asm.add(:edx, :ebx)
              asm.label("rt_scenery_window_bend_kept")
              asm.add(:ecx, :edx)
              asm.cmp(:ecx, :ebx)
              asm.jb("rt_scenery_window_bend_inside")
              asm.sub(:ecx, :ebx)
              asm.label("rt_scenery_window_bend_inside")
              asm.mov(:edx, :ebx)
              asm.pop(:eax)
              asm.label("rt_scenery_window_wrapped_flat")
            end

            # rt_scenery_map_row called for the row PY of the screen.
            def emit_map_row_call(asm, memory)
              asm.push(:ebp)
              asm.mov(:ebp, at(memory, PY))
              asm.call("rt_scenery_map_row")
              asm.pop(:ebp)
            end

            # PY moved down a row, and back to +label+ while it is above the clip's bottom.
            def emit_next_py(asm, memory, label)
              asm.mov(:eax, at(memory, PY))
              asm.inc(:eax)
              asm.mov(at(memory, PY), :eax)
              asm.cmp(:eax, at(memory, CLIP_BOTTOM))
              asm.jl(label)
            end

            # rt_scenery_stamp, with SI at a background's record: its map onto the picture from its corner, as many
            # times across and down as its grid comes round on the screen (Reference#stamp_background).
            def emit_stamp(asm, memory)
              word = ->(name) { at(memory, name) }
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_stamp")
              asm.push(:gs)
              asm.mov_segment(:ax, :art)
              asm.mov(:gs, :ax)
              asm.mov(word.call(CLIP_LEFT), 0)
              asm.mov(word.call(CLIP_RIGHT), memory.screen.width)
              asm.mov(word.call(PY), 0) # the top of this time down
              asm.movzx(:eax, record.call(:down))
              asm.mov(word.call(ROUND), :eax)
              asm.label("rt_scenery_stamp_down")
              asm.mov(word.call(MY), 0)
              asm.label("rt_scenery_stamp_row")
              asm.movzx(:eax, record.call(:map_h))
              asm.cmp(word.call(MY), :eax)
              asm.jge("rt_scenery_stamp_down_done")
              asm.mov(:eax, word.call(PY))
              asm.add(:eax, word.call(MY))
              asm.cmp(:eax, memory.screen.height)
              asm.jge("rt_scenery_stamp_done")
              asm.movzx(:ecx, record.call(:across))
              asm.xor(:edx, :edx) # how far across this time is
              asm.label("rt_scenery_stamp_across")
              asm.push(:ecx)
              asm.push(:edx)
              asm.push(:ebp)
              asm.mov(:ebp, :eax)
              asm.push(:eax)
              asm.mov(:ecx, :edx)
              asm.neg(:ecx)
              asm.mov(:eax, word.call(MY))
              asm.xor(:edx, :edx)
              asm.call("rt_scenery_map_row")
              asm.pop(:eax)
              asm.pop(:ebp)
              asm.pop(:edx)
              asm.pop(:ecx)
              asm.movzx(:ebx, record.call(:step_x))
              asm.add(:edx, :ebx)
              asm.dec(:ecx)
              asm.jne("rt_scenery_stamp_across")
              asm.mov(:eax, word.call(MY))
              asm.inc(:eax)
              asm.mov(word.call(MY), :eax)
              asm.jmp("rt_scenery_stamp_row")
              asm.label("rt_scenery_stamp_down_done")
              asm.movzx(:eax, record.call(:step_y))
              asm.add(word.call(PY), :eax)
              asm.mov(:eax, word.call(ROUND))
              asm.dec(:eax)
              asm.mov(word.call(ROUND), :eax)
              asm.jne("rt_scenery_stamp_down")
              asm.label("rt_scenery_stamp_done")
              asm.pop(:gs)
              Runtime.emit_mark_every_row(asm, memory)
              asm.ret
            end

            # rt_scenery_map_row: one row of the screen, EBP, from row EAX (not below nought) of the map of the
            # background whose record SI is at (GS at the art), with the screen's first pixel showing the map's
            # column ECX, the map coming round at its grid's edge where EDX is not nought (ECX is then inside the
            # grid), and not at all where it is (Reference#paint_background_window's walk along a row). Keeps SI
            # and EBP.
            #
            # THIS IS WHERE A FRAME'S TIME GOES: a scrolled view runs it for every row of every background, and a
            # fast 486 has some 430,000 instructions a frame. So the division is done once a row, not once a tile;
            # a cell holds where its tile's pixels are, so it is followed and never multiplied; a map that comes
            # round is kept as wide as its grid, so the row's place in it only goes back to the row's start at
            # the edge; and the pixels go four at a time: a solid tile's copied, and one with see-through pixels
            # laid with its mask (the picture kept where the mask is set, the tile's pixel put in where it is not).
            # While the row is drawn DS is the art, and the row's own numbers are read through SS.
            def emit_map_row(asm, memory)
              half = ->(name) { at(memory, name, 16) }
              kept = ->(name) { X86.mem(nil, memory[name], seg: :ss, size: 16) }
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_map_row")
              asm.push(:si)
              asm.push(:ebp)
              asm.mov(at(memory, OFF_X), :ecx)
              asm.mov(half.call(WRAPS), 0)
              asm.test(:edx, :edx)
              asm.je("rt_scenery_map_row_once")
              asm.mov(:bx, record.call(:wraps)) # not every background that is painted round comes round
              asm.mov(half.call(WRAPS), :bx)
              asm.label("rt_scenery_map_row_once")
              # Which row of cells, and which row of their tiles.
              asm.movzx(:ebx, record.call(:tile_h))
              asm.xor(:edx, :edx)
              asm.div(:ebx)
              asm.movzx(:ebx, record.call(:rows))
              asm.cmp(:eax, :ebx)
              asm.jae("rt_scenery_map_row_done")
              asm.movzx(:ecx, record.call(:cols))
              asm.imul(:eax, :ecx)
              asm.shl(:eax, 1)
              asm.add(:ax, record.call(:cells))
              asm.mov(half.call(ROW_BEGIN), :ax)
              asm.shl(:cx, 1)
              asm.add(:ax, :cx)
              asm.mov(half.call(ROW_END), :ax)
              asm.movzx(:eax, record.call(:tile_w))
              asm.mov(half.call(TILE_W), :ax)
              asm.imul(:eax, :edx)
              asm.mov(half.call(ROW_OFFSET), :ax)
              asm.mov(:ax, record.call(:mixed))
              asm.mov(half.call(MIXED), :ax)
              asm.mov(:ax, record.call(:mask_delta))
              asm.mov(half.call(MASK_DELTA), :ax)
              asm.mov(:ax, record.call(:colors_offset))
              asm.mov(half.call(COLORS_OFFSET), :ax)
              # The first pixel's column of the map, at the clip's left: left of a map that does not come round, the
              # row starts at the map's left edge, and past a sum too big for a number, right of it.
              asm.mov(:ecx, at(memory, CLIP_LEFT)) # the first pixel of the screen drawn
              asm.mov(:eax, at(memory, OFF_X))
              asm.add(:eax, :ecx)
              asm.jno("rt_scenery_map_row_summed")
              asm.cmp(half.call(WRAPS), 0) # a map that comes round is scrolled inside its grid, so never this far
              asm.je("rt_scenery_map_row_done")
              asm.label("rt_scenery_map_row_summed")
              asm.cmp(half.call(WRAPS), 0)
              asm.jne("rt_scenery_map_row_first")
              asm.test(:eax, :eax)
              asm.jns("rt_scenery_map_row_first")
              asm.sub(:ecx, :eax)
              asm.xor(:eax, :eax)
              asm.cmp(:ecx, at(memory, CLIP_RIGHT)) # with no sign: the furthest left of all, -2^31, stays that once turned round
              asm.jae("rt_scenery_map_row_done")
              asm.label("rt_scenery_map_row_first")
              asm.push(:ecx)
              asm.movzx(:ebx, half.call(TILE_W))
              asm.xor(:edx, :edx)
              asm.div(:ebx) # EAX the column, EDX how far into its tile
              asm.pop(:ecx)
              asm.movzx(:ebx, record.call(:cols))
              asm.cmp(half.call(WRAPS), 0)
              asm.je("rt_scenery_map_row_column")
              asm.label("rt_scenery_map_row_round") # a clip's left past the grid's edge, brought round
              asm.cmp(:eax, :ebx)
              asm.jb("rt_scenery_map_row_column")
              asm.sub(:eax, :ebx)
              asm.jmp("rt_scenery_map_row_round")
              asm.label("rt_scenery_map_row_column")
              asm.cmp(:eax, :ebx)
              asm.jae("rt_scenery_map_row_done") # right of a map that does not come round: nothing at all
              asm.mov(:bx, :ax)
              asm.add(:bx, :bx)
              asm.add(:bx, half.call(ROW_BEGIN)) # the cell, from here on
              asm.push(:dx)
              asm.push(:cx)
              Rows.emit_row_start(asm, memory.screen, :ebp)
              asm.pop(:cx)
              asm.add(:di, :cx)
              asm.mov(:bp, at(memory, CLIP_RIGHT, 16))
              asm.sub(:bp, :cx) # the pixels of the row still to go
              asm.pop(:dx) # how far into the first tile
              asm.mov(:cx, half.call(TILE_W))
              asm.sub(:cx, :dx)
              asm.add(:dx, half.call(ROW_OFFSET))
              asm.push(:ds)
              asm.push(:gs)
              asm.pop(:ds)

              # A run: the part of one tile the row shows, CX pixels, from DX into the tile's pixels.
              asm.label("rt_scenery_map_row_run")
              asm.cmp(:cx, :bp)
              asm.jbe("rt_scenery_map_row_run_kept")
              asm.mov(:cx, :bp)
              asm.label("rt_scenery_map_row_run_kept")
              asm.sub(:bp, :cx)
              asm.mov(:ax, X86.mem(:bx, 0, size: 16))
              asm.add(:bx, 2)
              asm.cmp(:ax, NO_TILE)
              asm.je("rt_scenery_map_row_empty")
              asm.mov(:si, :ax)
              asm.add(:si, :dx)
              asm.add(:si, kept.call(COLORS_OFFSET))
              asm.cmp(:ax, kept.call(MIXED))
              asm.jae("rt_scenery_map_row_mixed")
              asm.mov(:ax, :cx)
              asm.shr(:cx, 2)
              asm.movs(32, rep: true)
              asm.mov(:cx, :ax)
              asm.and(:cx, 3)
              asm.movs(8, rep: true)
              asm.jmp("rt_scenery_map_row_next")

              asm.label("rt_scenery_map_row_mixed")
              asm.push(:bx)
              asm.mov(:bx, :si)
              asm.add(:bx, kept.call(MASK_DELTA))
              asm.label("rt_scenery_map_row_four")
              asm.cmp(:cx, 4)
              asm.jb("rt_scenery_map_row_one")
              asm.mov(:eax, X86.mem(:di, 0, seg: :es, size: 32))
              asm.and(:eax, X86.mem(:bx, 0, size: 32))
              asm.or(:eax, X86.mem(:si, 0, size: 32))
              asm.stos(32)
              asm.add(:si, 4)
              asm.add(:bx, 4)
              asm.sub(:cx, 4)
              asm.jmp("rt_scenery_map_row_four")
              asm.label("rt_scenery_map_row_one")
              asm.test(:cx, :cx)
              asm.je("rt_scenery_map_row_laid")
              asm.mov(:al, X86.mem(:di, 0, seg: :es, size: 8))
              asm.and(:al, X86.mem(:bx, 0, size: 8))
              asm.or(:al, X86.mem(:si, 0, size: 8))
              asm.stos(8)
              asm.inc(:si)
              asm.inc(:bx)
              asm.dec(:cx)
              asm.jmp("rt_scenery_map_row_one")
              asm.label("rt_scenery_map_row_laid")
              asm.pop(:bx)
              asm.jmp("rt_scenery_map_row_next")

              asm.label("rt_scenery_map_row_empty")
              asm.add(:di, :cx)
              asm.label("rt_scenery_map_row_next")
              asm.cmp(:bx, kept.call(ROW_END))
              asm.jb("rt_scenery_map_row_same_round")
              asm.cmp(kept.call(WRAPS), 0)
              asm.je("rt_scenery_map_row_finished") # past the right of a map that does not come round
              asm.mov(:bx, kept.call(ROW_BEGIN))
              asm.label("rt_scenery_map_row_same_round")
              asm.mov(:dx, kept.call(ROW_OFFSET))
              asm.mov(:cx, kept.call(TILE_W))
              asm.test(:bp, :bp)
              asm.jne("rt_scenery_map_row_run")
              asm.label("rt_scenery_map_row_finished")
              asm.pop(:ds)
              asm.label("rt_scenery_map_row_done")
              asm.pop(:ebp)
              asm.pop(:si)
              asm.ret
            end
          end
        end
      end
    end
  end
end
