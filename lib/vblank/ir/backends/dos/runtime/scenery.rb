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
          # entry a pixel) and its map (a word a cell, row after row); the records' order for building the view is
          # a list of their places, its length first. In the data segment each has its scroll and whether it shows
          # from its corner (STATE).
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
            RECORD = %i[cells cols rows tile_w tile_h wrap_w wrap_h wraps across down step_x step_y map_h state mixed
                        mask_delta lengths maps map_count colors_offset].freeze
            RECORD_BYTES = 40
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

            # A background's place in the data segment: its scroll, whether it shows from its corner, and the place
            # the view was last built showing it from.
            STATE_BYTES = 24
            SCROLL_X = 0
            SCROLL_Y = 4
            FROM_CORNER = 8
            BUILT_X = 12
            BUILT_Y = 16
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
            NEXT = "rt scenery next"

            WORDS = [OWED, EXPIRED, ANY_FROM_CORNER, UP, PLACING, BACKDROP, BUILT, BUILT_BACKDROP, ROW_BEGIN, ROW_END, ROW_OFFSET,
                     TILE_W, MIXED, MASK_DELTA, COLORS_OFFSET, WRAPS, OFF_X,
                     PY, MY, ROUND, SCROLL_SHOWN_X, SCROLL_SHOWN_Y, NEXT].freeze

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

            # +order+ is the art segment's place of the list of records the view is built from, and +backgrounds+
            # how many there are. +cells+, +held+ and +maps+ say whether the game changes a cell, holds a change for
            # the frame's end, or shows another map.
            def emit(asm, memory, order:, backgrounds:, cells: false, held: false, maps: false, runs: false)
              emit_requests(asm, memory, backgrounds, held: held)
              emit_paint_run(asm, memory) if runs
              emit_set_cell(asm, memory) if cells
              emit_held(asm, memory) if held
              emit_show_map(asm, memory) if maps
              emit_backdrop(asm, memory)
              emit_view(asm, memory, order, backgrounds)
              emit_window(asm, memory)
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
            def emit_requests(asm, memory, backgrounds, held: false)
              word = ->(name) { at(memory, name) }
              # rt_scenery_rebuild: the view owed and built again, since what it is built from has changed.
              asm.label("rt_scenery_rebuild")
              asm.mov(word.call(BUILT), 0)
              asm.label("rt_scenery_request")
              asm.call("rt_scenery_forget_corners")
              asm.mov(word.call(OWED), 1)
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

              asm.label("rt_scenery_put_up")
              if held
                asm.push(:bx)
                asm.call("rt_scenery_forget_held")
                asm.pop(:bx)
              end
              asm.call("rt_scenery_forget_corners")
              asm.mov(X86.mem(:bx, FROM_CORNER, size: 32), 1)
              asm.mov(word.call(ANY_FROM_CORNER), 1)
              asm.mov(word.call(UP), 1)
              asm.mov(word.call(BUILT), 0)
              asm.jmp("rt_scenery_stamp")

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

            # rt_scenery_view: the whole view built again (Reference#repaint_view): the backdrop, then each
            # background's window, in the order the list at +order+ in the art segment holds them.
            #
            # The interpreter builds it every pass in a game that scrolls. What it builds depends on nothing but the
            # backdrop and where each background shows from, so where the picture is still the view last built
            # (BUILT) and none of those has changed, building it again would make the same picture, and is left.
            def emit_view(asm, memory, order, backgrounds)
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
              asm.mov(at(memory, BUILT), 1)
              asm.mov(:al, at(memory, BACKDROP, 8))
              asm.mov(at(memory, BUILT_BACKDROP, 8), :al)
              emit_fill_with_backdrop(asm, memory, "rt_scenery_view")
              asm.push(:gs)
              asm.mov_segment(:ax, :art)
              asm.mov(:gs, :ax)
              asm.mov(at(memory, NEXT, 16), order + 2)
              asm.mov(:cx, X86.mem(nil, order, seg: :gs, size: 16))
              asm.label("rt_scenery_view_next")
              asm.test(:cx, :cx)
              asm.je("rt_scenery_view_done")
              asm.push(:cx)
              asm.mov(:bx, at(memory, NEXT, 16))
              asm.mov(:si, X86.mem(:bx, 0, seg: :gs, size: 16))
              asm.add(at(memory, NEXT, 16), 2)
              asm.call("rt_scenery_window")
              asm.pop(:cx)
              asm.dec(:cx)
              asm.jmp("rt_scenery_view_next")
              asm.label("rt_scenery_view_done")
              asm.pop(:gs)
              asm.ret
            end

            # rt_scenery_window, with SI at a background's record and GS at the art: its window painted where it is
            # scrolled to, or from its corner (Reference#paint_background_window, #paint_streamed_background_window).
            def emit_window(asm, memory)
              word = ->(name) { at(memory, name) }
              record = ->(name) { X86.mem(:si, field(name), seg: :gs, size: 16) }
              asm.label("rt_scenery_window")
              asm.mov(:bx, record.call(:state))
              asm.xor(:eax, :eax)
              asm.xor(:ecx, :ecx)
              asm.cmp(X86.mem(:bx, FROM_CORNER, size: 32), 0)
              asm.jne("rt_scenery_window_placed")
              asm.mov(:eax, X86.mem(:bx, SCROLL_X, size: 32))
              asm.mov(:ecx, X86.mem(:bx, SCROLL_Y, size: 32))
              asm.label("rt_scenery_window_placed")
              asm.mov(X86.mem(:bx, BUILT_X, size: 32), :eax)
              asm.mov(X86.mem(:bx, BUILT_Y, size: 32), :ecx)
              asm.mov(word.call(SCROLL_SHOWN_X), :eax)
              asm.mov(word.call(SCROLL_SHOWN_Y), :ecx)
              asm.mov(word.call(PY), 0)
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
              emit_map_row_call(asm, memory)
              emit_next_py(asm, memory, "rt_scenery_window_wrapped_row")
              asm.ret
            end

            # rt_scenery_map_row called for the row PY of the screen.
            def emit_map_row_call(asm, memory)
              asm.push(:ebp)
              asm.mov(:ebp, at(memory, PY))
              asm.call("rt_scenery_map_row")
              asm.pop(:ebp)
            end

            # PY moved down a row, and back to +label+ while it is on the screen.
            def emit_next_py(asm, memory, label)
              asm.mov(:eax, at(memory, PY))
              asm.inc(:eax)
              asm.mov(at(memory, PY), :eax)
              asm.cmp(:eax, memory.screen.height)
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
              width = memory.screen.width
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
              # The first pixel's column of the map: left of a map that does not come round, the row starts at the
              # map's left edge.
              asm.mov(:eax, at(memory, OFF_X))
              asm.xor(:ecx, :ecx) # the first pixel of the screen drawn
              asm.cmp(half.call(WRAPS), 0)
              asm.jne("rt_scenery_map_row_first")
              asm.test(:eax, :eax)
              asm.jns("rt_scenery_map_row_first")
              asm.mov(:ecx, :eax)
              asm.neg(:ecx)
              asm.xor(:eax, :eax)
              asm.cmp(:ecx, width) # with no sign: the furthest left of all, -2^31, stays that once turned round
              asm.jae("rt_scenery_map_row_done")
              asm.label("rt_scenery_map_row_first")
              asm.push(:ecx)
              asm.movzx(:ebx, half.call(TILE_W))
              asm.xor(:edx, :edx)
              asm.div(:ebx) # EAX the column, EDX how far into its tile
              asm.pop(:ecx)
              asm.movzx(:ebx, record.call(:cols))
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
              asm.mov(:bp, width)
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
