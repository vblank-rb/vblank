# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # TEXT AS A LAYER OF ITS OWN over a painted screen, as the console's own games keep their
          # text (SNES::TextLayerArt says why, and draws the tiles).
          #
          # Mode 3 has a second background, four bits a pixel, which the painted screen does not
          # use. Its tiles are the text's, copied into video RAM with the screen off at power-on;
          # its map is in front of the painted layer (its cells have the priority bit, the painted
          # layer's do not), and a cell showing nothing shows the painted layer through it. So a
          # text the game writes at a place known when it is built is a few cells of that map
          # (rt_paint_layer_text): nothing is painted, and only the rows of the map that changed are
          # sent, with the painted layer's map, in the blank the pass is shown in.
          #
          # VIDEO RAM. The painted screen's tiles fill it to $6FFF (Paint), so this layer needs the
          # room the painted layer's map keeps for the camera: a game with a text layer has no
          # camera (Lowering::Paint.text_layer?), its painted map is 32 cells by 32, and the layer's
          # map takes the 32 by 32 after it:
          #
          #   $7000-$73FF  the painted layer's map
          #   $7400-$77FF  the text layer's map
          #   $78A0-$7FFF  the text layer's tiles, from tile 138 (its tiles count from $7000)
          #
          # IN FRONT MEANS LAST. A text on the layer shows over everything painted, so it is right
          # only while nothing painted after it covers it. A painting that would touch a tile a text
          # covers takes that text off the layer first and paints it, where it was drawn among the
          # paintings (DEMOTED): with PaintLog its entry in the log becomes a picture painted there,
          # so a pass's paintings still come out in the order the game drew them. Painting a text
          # rather than showing it on the layer gives the same pixels, so taking one off is always
          # right; only leaving one on needs nothing over it. A pass that paints at once (with no
          # clear, PaintLog's LOGGING) paints every text on the layer at once first.
          #
          # A pass that clears the screen clears the layer, as the clear is made (a clear deferred
          # leaves it, as it leaves the painted layer: the screen still shows the last pass).
          #
          #   rt_paint_layer_text     a text on the layer, or painted where it cannot be
          #   rt_paint_layer_check    a painting about to cover tiles: texts there taken off first
          #   rt_paint_layer_upload   in the blank: the rows of the layer's map that changed
          module TextLayer
            MAP = 0x7400
            TILES_BASE = 0x7000
            FIRST_TILE_AT = TILES_BASE + (TextLayerArt::FIRST_TILE * TextLayerArt::TILE_BYTES / 2)
            ROWS = Paint::ROWS
            ROW_BYTES = Paint::COLUMNS * 2
            # BG12NBA: the painted layer's tiles at $0000, this one's at $7000. BG2SC: its map at
            # $7400, 32 cells by 32.
            NAME_BASES = TILES_BASE >> 8
            MAP_REGISTER = (MAP >> 10) << 2
            # The most texts on the layer at once. The log keeps room for an entry for each, for the
            # texts a painting takes off the layer (rt_paint_layer_demote).
            MOST_PLACED = 32
            # The layer's map rows 0 to 27 as video RAM is to have them, a word a cell.
            CELLS = "rt paint layer cells"
            # For each row of tiles, which of its 32 columns a text on the layer covers, a bit each
            # (four bytes, column 0 the lowest bit).
            ROWS_USED = "rt paint layer rows used"
            # The first and last rows of the map to send (none: the first past the last), all the
            # rows between them in one copy, and the bytes of it, as the blank counts them
            # (Paint::RUN_SETTING_UP for its setting up). One copy of every row from the first changed
            # to the last costs the blank less than a copy of each changed row: a copy's setting up
            # is longer than a row.
            CHANGED_FIRST = "rt paint layer changed first"
            CHANGED_LAST = "rt paint layer changed last"
            CHANGED_BYTES = "rt paint layer changed bytes"
            # The texts on the layer, by number, in the order they were put there, and how many.
            PLACED = "rt paint layer placed"
            COUNT = "rt paint layer count"
            # The text at hand (rt_paint_layer_find): its record's place in the table, then its
            # number, rows, columns, the mask of its columns, its hash and the picture it stands for.
            AT = "rt paint layer at"
            TEXT = "rt paint layer text"
            T_NUMBER = 0
            T_TOP = 2
            T_BOTTOM = 4
            T_FIRST = 6
            T_LAST = 8
            T_MASK = 10
            T_HASH = 14
            T_PICTURE = 18
            T_X = 20
            T_Y = 22
            TEXT_BYTES = 24
            # A painting's rows and columns of tiles (rt_paint_layer_check), the columns as a mask,
            # and the row and list place at hand.
            RECT = "rt paint layer rect"
            COLUMNS_MASK = "rt paint layer columns mask"
            ROW = "rt paint layer row"
            CELLS_LEFT = "rt paint layer cells left"
            ROW_START = "rt paint layer row start"
            LISTED = "rt paint layer listed"
            # The direct page, kept while texts are painted at once (rt_paint_layer_check_now).
            KEPT_PAGE = "rt paint layer kept page"

            # A text's record in "paint layer texts" (TextLayerArt#emit_tables).
            R_PICTURE = 0
            R_X = 2
            R_Y = 4
            R_TOP = 6
            R_BOTTOM = 8
            R_FIRST = 10
            R_LAST = 12
            R_MASK = 14
            R_HASH = 18
            R_CELLS = 22

            module_function

            def reserve(memory)
              memory.reserve_far(CELLS, ROWS * ROW_BYTES)
              memory.reserve_far(KEPT_PAGE, 0x100)
              memory.reserve(ROWS_USED, ROWS * 4)
              memory.reserve(PLACED, MOST_PLACED * 2)
              memory.reserve(TEXT, TEXT_BYTES)
              memory.reserve(RECT, 8)
              memory.reserve(COLUMNS_MASK, 4)
              [CHANGED_FIRST, CHANGED_LAST, CHANGED_BYTES, COUNT, AT, ROW, CELLS_LEFT, ROW_START, LISTED].each { |name| memory.reserve(name, 2) }
            end

            # Whether +memory+ keeps a text layer, which every part of the painted screen asks.
            def kept?(memory) = memory.reserved?(COUNT)

            # +limit+ is the log's bytes less the room it keeps for texts taken off the layer.
            def emit(asm, memory, s, limit)
              emit_start(asm, memory)
              emit_text(asm, memory, s, limit)
              emit_find(asm, memory, s)
              emit_free(asm, memory)
              emit_place(asm, memory, s)
              emit_remove(asm, memory)
              emit_clear_all(asm, memory)
              emit_row_changed(asm, memory)
              emit_check(asm, memory, s)
              emit_demote(asm, memory, s)
              emit_check_now(asm, memory, s)
              emit_replace(asm, memory)
              emit_upload(asm, memory)
              emit_tables(asm)
            end

            # rt_paint_layer_start (JSR, with the screen off, from Paint's rt_paint_start): the
            # layer's registers, its tiles, its map all empty.
            def emit_start(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_paint_layer_start")
              asm.sep(0x20)
              asm.lda(NAME_BASES)
              asm.sta(asm.abs(h::BG12NBA))
              asm.lda(MAP_REGISTER)
              asm.sta(asm.abs(h::BG2SC))
              # Scrolled up one, as the painted layer is (Paint's rt_paint_start).
              asm.lda(0xFF)
              asm.sta(asm.abs(h::BG2VOFS))
              asm.lda(0x03)
              asm.sta(asm.abs(h::BG2VOFS))
              asm.rep(0x20)
              Picture.emit_dma_to_vram(asm, FIRST_TILE_AT, "paint layer tiles", "paint layer tile bytes")
              asm.lda(MAP)
              asm.sta(asm.abs(h::VMADDL))
              Picture.emit_dma(asm, h::DMA_TO_TWO_PORTS | h::DMA_FIXED_SOURCE, h::VMDATAL, asm.imm("rt_paint_layer_empty_byte"),
                               asm.bank_of("rt_paint_layer_empty_byte"), Paint::COLUMNS * 32 * 2)
              Paint.emit_fill_work_ram(asm, memory[CELLS], ROWS * ROW_BYTES, "rt_paint_layer_empty_byte")
              asm.ldx(0)
              asm.label("rt_paint_layer_start_row")
              asm.stz(asm.abs_x(memory[ROWS_USED]))
              asm.stz(asm.abs_x(memory[ROWS_USED] + 2))
              4.times { asm.inx }
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_layer_start_row")
              asm.stz(asm.abs(memory[COUNT]))
              emit_none_changed(asm, memory)
              asm.rts
            end

            # No row of the map to send.
            def emit_none_changed(asm, memory)
              asm.lda(ROWS)
              asm.sta(asm.abs(memory[CHANGED_FIRST]))
              asm.stz(asm.abs(memory[CHANGED_LAST]))
              asm.stz(asm.abs(memory[CHANGED_BYTES]))
            end

            # rt_paint_layer_text(text, picture, x, y) (JSL): the text numbered +text+ on the layer,
            # standing for +picture+ painted at (+x+, +y+). Passed over while a clear is deferred and
            # the last pass put it there too (PaintLog). Painted, as the picture, when paintings are
            # not written down (the pass did not clear), inside an area, when the layer is full or
            # another text covers its tiles: a painting that covers the other takes it off the layer
            # first, so the two still come out in order.
            def emit_text(asm, memory, s, limit)
              log = memory[PaintLog::LOG]
              area = memory[Paint::AREA]
              text = memory[TEXT]
              asm.label("rt_paint_layer_text")
              asm.lda(asm.abs(memory[PaintLog::DEFERRED_CLEAR]))
              asm.beq("rt_paint_layer_text_written")
              asm.ldx(asm.abs(memory[PaintLog::LOG_END]))
              asm.cpx(asm.abs(memory[PaintLog::LAST_PASS_END]))
              asm.bcs("rt_paint_layer_text_differs")
              asm.lda(asm.long_x(log))
              asm.ora(1) # on the layer, or taken off it, both with the whole screen for their area
              asm.cmp(PaintLog::KIND_DEMOTED)
              asm.bne("rt_paint_layer_text_differs")
              asm.lda(asm.direct(Paint::R.call(0)))
              asm.cmp(asm.long_x(log, PaintLog::ENTRY_NUMBERS))
              asm.bne("rt_paint_layer_text_differs")
              asm.txa
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.sta(asm.abs(memory[PaintLog::LOG_END]))
              asm.rtl
              asm.label("rt_paint_layer_text_differs")
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear"))
              asm.label("rt_paint_layer_text_written")
              asm.lda(asm.abs(memory[PaintLog::LOGGING]))
              asm.branch_long(:beq, "rt_paint_layer_text_painted")
              asm.lda(asm.abs(area + Paint::AREA_PART))
              asm.branch_long(:bne, "rt_paint_layer_text_painted")
              asm.lda(asm.abs(memory[COUNT]))
              asm.cmp(MOST_PLACED)
              asm.branch_long(:bcs, "rt_paint_layer_text_painted")
              asm.lda(asm.abs(memory[PaintLog::LOG_END]))
              asm.cmp(limit)
              asm.bcc("rt_paint_layer_text_room")
              asm.jsr(asm.abs("rt_paint_flush_keeping"))
              asm.label("rt_paint_layer_text_room")
              asm.lda(asm.direct(Paint::R.call(0)))
              asm.jsr(asm.abs("rt_paint_layer_find"))
              asm.jsr(asm.abs("rt_paint_layer_free"))
              asm.branch_long(:bne, "rt_paint_layer_text_painted")
              asm.jsr(asm.abs("rt_paint_layer_place"))
              # Written down, as PaintLog writes a painting down, its tiles those it covers.
              asm.ldx(asm.abs(memory[PaintLog::LOG_END]))
              asm.lda(PaintLog::KIND_LAYER)
              asm.sta(asm.long_x(log))
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.long_x(log, PaintLog::ENTRY_AREA + (i * 2)))
              end
              8.times do |i|
                asm.lda(asm.direct(i * 2))
                asm.sta(asm.long_x(log, PaintLog::ENTRY_NUMBERS + (i * 2)))
              end
              asm.lda(0)
              asm.sta(asm.long_x(log, PaintLog::ENTRY_NUMBERS + 16))
              asm.sta(asm.long_x(log, PaintLog::ENTRY_NUMBERS + 18))
              emit_entry_tiles(asm, log, text)
              asm.txa
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.sta(asm.abs(memory[PaintLog::LOG_END]))
              asm.rtl
              # Painted: the picture, at the place.
              asm.label("rt_paint_layer_text_painted")
              6.times do |i|
                asm.lda(asm.direct(Paint::R.call(1) + (i * 2)))
                asm.sta(asm.direct(Paint::R.call(0) + (i * 2)))
              end
              asm.jmp(asm.abs("rt_paint_blit"))
            end

            # The entry at X of the log (at +log+) given the text at hand's rows, columns and hash.
            def emit_entry_tiles(asm, log, text)
              [[T_TOP, PaintLog::ENTRY_TOP], [T_BOTTOM, PaintLog::ENTRY_BOTTOM], [T_FIRST, PaintLog::ENTRY_FIRST],
               [T_LAST, PaintLog::ENTRY_LAST], [T_HASH, PaintLog::ENTRY_HASH], [T_HASH + 2, PaintLog::ENTRY_HASH + 2]].each do |from, to|
                asm.lda(asm.abs(text + from))
                asm.sta(asm.long_x(log, to))
              end
            end

            # rt_paint_layer_find (JSR, A a text's number): the text at hand made that one (TEXT and
            # AT), and +pointer+ pointed at its cells. Uses X.
            def emit_find(asm, memory, s)
              text = memory[TEXT]
              asm.label("rt_paint_layer_find")
              asm.sta(asm.abs(text + T_NUMBER))
              5.times { asm.asl }
              asm.sta(asm.abs(memory[AT]))
              asm.tax
              [[R_TOP, T_TOP], [R_BOTTOM, T_BOTTOM], [R_FIRST, T_FIRST], [R_LAST, T_LAST], [R_MASK, T_MASK],
               [R_MASK + 2, T_MASK + 2], [R_HASH, T_HASH], [R_HASH + 2, T_HASH + 2], [R_PICTURE, T_PICTURE],
               [R_X, T_X], [R_Y, T_Y]].each do |from, to|
                asm.lda(asm.long_x("paint layer texts", from))
                asm.sta(asm.abs(text + to))
              end
              asm.lda(asm.long_x("paint layer texts", R_CELLS))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint layer texts", R_CELLS + 2))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(s.pointer + 2))
              asm.rts
            end

            # rt_paint_layer_free (JSR): A nought when no text on the layer covers a tile the text at
            # hand covers. Uses X.
            def emit_free(asm, memory)
              text = memory[TEXT]
              used = memory[ROWS_USED]
              asm.label("rt_paint_layer_free")
              asm.lda(asm.abs(text + T_TOP))
              asm.asl
              asm.asl
              asm.tax
              asm.label("rt_paint_layer_free_row")
              asm.lda(asm.abs_x(used))
              asm.and_a(asm.abs(text + T_MASK))
              asm.bne("rt_paint_layer_free_not")
              asm.lda(asm.abs_x(used + 2))
              asm.and_a(asm.abs(text + T_MASK + 2))
              asm.bne("rt_paint_layer_free_not")
              asm.txa
              asm.lsr
              asm.lsr
              asm.cmp(asm.abs(text + T_BOTTOM))
              asm.beq("rt_paint_layer_free_yes")
              4.times { asm.inx }
              asm.bra("rt_paint_layer_free_row")
              asm.label("rt_paint_layer_free_yes")
              asm.lda(0)
              asm.rts
              asm.label("rt_paint_layer_free_not")
              asm.lda(1)
              asm.rts
            end

            # rt_paint_layer_place (JSR): the text at hand on the layer — its columns taken in each of
            # its rows, its cells into the map, the rows to send, and the text on the list. Uses X
            # and Y.
            def emit_place(asm, memory, s)
              text = memory[TEXT]
              used = memory[ROWS_USED]
              row = memory[ROW]
              asm.label("rt_paint_layer_place")
              asm.ldy(0)
              asm.lda(asm.abs(text + T_TOP))
              asm.sta(asm.abs(row))
              asm.label("rt_paint_layer_place_row")
              asm.lda(asm.abs(row))
              asm.asl
              asm.asl
              asm.tax
              2.times do |half|
                asm.lda(asm.abs_x(used + (half * 2)))
                asm.ora(asm.abs(text + T_MASK + (half * 2)))
                asm.sta(asm.abs_x(used + (half * 2)))
              end
              asm.jsr(asm.abs("rt_paint_layer_row_changed"))
              emit_row_cells(asm, memory)
              asm.label("rt_paint_layer_place_cell")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.long_x(memory[CELLS]))
              asm.iny
              asm.iny
              asm.inx
              asm.inx
              asm.dec(asm.abs(memory[CELLS_LEFT]))
              asm.bne("rt_paint_layer_place_cell")
              asm.lda(asm.abs(row))
              asm.cmp(asm.abs(text + T_BOTTOM))
              asm.beq("rt_paint_layer_place_listed")
              asm.inc(asm.abs(row))
              asm.bra("rt_paint_layer_place_row")
              asm.label("rt_paint_layer_place_listed")
              asm.lda(asm.abs(memory[COUNT]))
              asm.asl
              asm.tax
              asm.lda(asm.abs(text + T_NUMBER))
              asm.sta(asm.abs_x(memory[PLACED]))
              asm.inc(asm.abs(memory[COUNT]))
              asm.rts
            end

            # X at the text at hand's first cell of ROW in CELLS, and CELLS_LEFT its columns.
            def emit_row_cells(asm, memory)
              text = memory[TEXT]
              asm.lda(asm.abs(memory[ROW]))
              asm.xba
              asm.lsr
              asm.lsr # 64 bytes a row
              asm.sta(asm.abs(memory[ROW_START]))
              asm.lda(asm.abs(text + T_FIRST))
              asm.asl
              asm.clc
              asm.adc(asm.abs(memory[ROW_START]))
              asm.tax
              asm.lda(asm.abs(text + T_LAST))
              asm.sec
              asm.sbc(asm.abs(text + T_FIRST))
              asm.inc
              asm.sta(asm.abs(memory[CELLS_LEFT]))
            end

            # rt_paint_layer_remove (JSR): the text at hand off the layer — its columns let go in each
            # of its rows, its cells empty, the rows to send, and the text off the list. Uses X.
            def emit_remove(asm, memory)
              text = memory[TEXT]
              used = memory[ROWS_USED]
              row = memory[ROW]
              placed = memory[PLACED]
              asm.label("rt_paint_layer_remove")
              asm.lda(asm.abs(text + T_TOP))
              asm.sta(asm.abs(row))
              asm.label("rt_paint_layer_remove_row")
              asm.lda(asm.abs(row))
              asm.asl
              asm.asl
              asm.tax
              2.times do |half|
                asm.lda(asm.abs(text + T_MASK + (half * 2)))
                asm.eor(0xFFFF)
                asm.and_a(asm.abs_x(used + (half * 2)))
                asm.sta(asm.abs_x(used + (half * 2)))
              end
              asm.jsr(asm.abs("rt_paint_layer_row_changed"))
              emit_row_cells(asm, memory)
              asm.lda(TextLayerArt::EMPTY_CELL)
              asm.label("rt_paint_layer_remove_cell")
              asm.sta(asm.long_x(memory[CELLS]))
              asm.inx
              asm.inx
              asm.dec(asm.abs(memory[CELLS_LEFT]))
              asm.bne("rt_paint_layer_remove_cell")
              asm.lda(asm.abs(row))
              asm.cmp(asm.abs(text + T_BOTTOM))
              asm.beq("rt_paint_layer_remove_unlist")
              asm.inc(asm.abs(row))
              asm.bra("rt_paint_layer_remove_row")
              # Off the list: the texts after it moved down one.
              asm.label("rt_paint_layer_remove_unlist")
              asm.lda(asm.abs(memory[COUNT]))
              asm.asl
              asm.sta(asm.abs(memory[CELLS_LEFT])) # the list's end, in bytes
              asm.ldx(0)
              asm.label("rt_paint_layer_remove_find")
              asm.cpx(asm.abs(memory[CELLS_LEFT]))
              asm.bcs("rt_paint_layer_remove_done")
              asm.lda(asm.abs_x(placed))
              asm.cmp(asm.abs(text + T_NUMBER))
              asm.beq("rt_paint_layer_remove_found")
              asm.inx
              asm.inx
              asm.bra("rt_paint_layer_remove_find")
              asm.label("rt_paint_layer_remove_found")
              asm.inx
              asm.inx
              asm.cpx(asm.abs(memory[CELLS_LEFT]))
              asm.bcs("rt_paint_layer_remove_shifted")
              asm.lda(asm.abs_x(placed))
              asm.sta(asm.abs_x(placed - 2))
              asm.bra("rt_paint_layer_remove_found")
              asm.label("rt_paint_layer_remove_shifted")
              asm.dec(asm.abs(memory[COUNT]))
              asm.label("rt_paint_layer_remove_done")
              asm.rts
            end

            # rt_paint_layer_clear_all (JSR): no text on the layer, every row a text was in emptied
            # and to be sent. The list is left as it was, its count nought. Uses X and Y.
            def emit_clear_all(asm, memory)
              used = memory[ROWS_USED]
              row = memory[ROW]
              asm.label("rt_paint_layer_clear_all")
              asm.lda(asm.abs(memory[COUNT]))
              asm.beq("rt_paint_layer_clear_all_done")
              asm.stz(asm.abs(row))
              asm.ldx(0)
              asm.label("rt_paint_layer_clear_all_row")
              asm.lda(asm.abs_x(used))
              asm.ora(asm.abs_x(used + 2))
              asm.beq("rt_paint_layer_clear_all_next")
              asm.stz(asm.abs_x(used))
              asm.stz(asm.abs_x(used + 2))
              asm.phx
              asm.jsr(asm.abs("rt_paint_layer_row_changed"))
              asm.lda(asm.abs(row))
              asm.xba
              asm.lsr
              asm.lsr
              asm.tax
              asm.lda(TextLayerArt::EMPTY_CELL)
              asm.ldy(Paint::COLUMNS)
              asm.label("rt_paint_layer_clear_all_cell")
              asm.sta(asm.long_x(memory[CELLS]))
              asm.inx
              asm.inx
              asm.dey
              asm.bne("rt_paint_layer_clear_all_cell")
              asm.plx
              asm.label("rt_paint_layer_clear_all_next")
              asm.inc(asm.abs(row))
              4.times { asm.inx }
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_layer_clear_all_row")
              asm.stz(asm.abs(memory[COUNT]))
              asm.label("rt_paint_layer_clear_all_done")
              asm.rts
            end

            # rt_paint_layer_row_changed (JSR): ROW among the rows to send in the blank, and their
            # bytes counted again.
            def emit_row_changed(asm, memory)
              first = memory[CHANGED_FIRST]
              last = memory[CHANGED_LAST]
              asm.label("rt_paint_layer_row_changed")
              asm.lda(asm.abs(memory[ROW]))
              asm.cmp(asm.abs(first))
              asm.bcs("rt_paint_layer_row_changed_first")
              asm.sta(asm.abs(first))
              asm.label("rt_paint_layer_row_changed_first")
              asm.cmp(asm.abs(last))
              asm.bcc("rt_paint_layer_row_changed_last")
              asm.sta(asm.abs(last))
              asm.label("rt_paint_layer_row_changed_last")
              asm.lda(asm.abs(last))
              asm.sec
              asm.sbc(asm.abs(first))
              asm.inc
              asm.xba
              asm.lsr
              asm.lsr # 64 bytes a row
              asm.clc
              asm.adc(Paint::RUN_SETTING_UP)
              asm.sta(asm.abs(memory[CHANGED_BYTES]))
              asm.rts
            end

            # The mask of the columns +first+ to +last+ (words on the direct page) into COLUMNS_MASK.
            def emit_columns_mask(asm, memory, first, last)
              mask = memory[COLUMNS_MASK]
              asm.lda(asm.direct(first))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("rt_paint_layer_from_column"))
              asm.sta(asm.abs(mask))
              asm.lda(asm.long_x("rt_paint_layer_from_column", 2))
              asm.sta(asm.abs(mask + 2))
              asm.lda(asm.direct(last))
              asm.asl
              asm.asl
              asm.tax
              2.times do |half|
                asm.lda(asm.long_x("rt_paint_layer_up_to_column", half * 2))
                asm.and_a(asm.abs(mask + (half * 2)))
                asm.sta(asm.abs(mask + (half * 2)))
              end
            end

            # Rows +top+ to +bottom+ of ROWS_USED (A the first), each against COLUMNS_MASK: on to
            # +covered+ at the first a text on the layer shares, else past. Uses X.
            def emit_rows_covered(asm, memory, bottom, covered, tag)
              used = memory[ROWS_USED]
              mask = memory[COLUMNS_MASK]
              asm.asl
              asm.asl
              asm.tax
              asm.label("#{tag}_row")
              asm.lda(asm.abs_x(used))
              asm.and_a(asm.abs(mask))
              asm.branch_long(:bne, covered)
              asm.lda(asm.abs_x(used + 2))
              asm.and_a(asm.abs(mask + 2))
              asm.branch_long(:bne, covered)
              asm.txa
              asm.lsr
              asm.lsr
              asm.cmp(bottom)
              asm.beq("#{tag}_none")
              4.times { asm.inx }
              asm.bra("#{tag}_row")
              asm.label("#{tag}_none")
            end

            # On to +stays+ unless the text at hand's tiles and RECT's (a painting's rows and columns
            # of tiles) share a row and a column.
            def emit_unless_rect_shared(asm, memory, stays)
              rect = memory[RECT]
              text = memory[TEXT]
              [[rect + 2, text + T_TOP], [text + T_BOTTOM, rect], [rect + 6, text + T_FIRST], [text + T_LAST, rect + 4]].each do |high, low|
                asm.lda(asm.abs(high))
                asm.cmp(asm.abs(low))
                asm.bcc(stays)
              end
            end

            # rt_paint_layer_check (JSR, at the top of PaintLog's rt_paint_mark_rows: rows of tiles
            # +mark_row+ to +temp+, columns +chunk+ to +last+, OP_HASH the painting's): each text on the
            # layer whose tiles those cover taken off it (rt_paint_layer_demote), so it is painted
            # under the painting. All that is on the direct page and OP_HASH is kept, as are X and Y.
            def emit_check(asm, memory, s)
              rect = memory[RECT]
              hash = memory[PaintLog::OP_HASH]
              asm.label("rt_paint_layer_check")
              asm.lda(asm.abs(memory[COUNT]))
              asm.bne("rt_paint_layer_check_look")
              asm.rts
              asm.label("rt_paint_layer_check_look")
              asm.phx
              asm.phy
              emit_columns_mask(asm, memory, s.chunk, s.last)
              asm.lda(asm.direct(s.mark_row))
              emit_rows_covered(asm, memory, asm.direct(s.temp), "rt_paint_layer_check_covered", "rt_paint_layer_check")
              asm.ply
              asm.plx
              asm.rts
              asm.label("rt_paint_layer_check_covered")
              kept = [s.mark_row, s.temp, s.chunk, s.last, s.pointer, s.pointer + 2]
              kept.each { |at| asm.pei(asm.direct(at)) }
              2.times do |half|
                asm.lda(asm.abs(hash + (half * 2)))
                asm.pha
              end
              [s.mark_row, s.temp, s.chunk, s.last].each_with_index do |from, i|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(rect + (i * 2)))
              end
              asm.stz(asm.abs(memory[LISTED]))
              asm.label("rt_paint_layer_check_text")
              asm.lda(asm.abs(memory[COUNT]))
              asm.asl
              asm.cmp(asm.abs(memory[LISTED]))
              asm.beq("rt_paint_layer_check_done")
              asm.bcc("rt_paint_layer_check_done")
              asm.ldx(asm.abs(memory[LISTED]))
              asm.lda(asm.abs_x(memory[PLACED]))
              asm.jsr(asm.abs("rt_paint_layer_find"))
              emit_unless_rect_shared(asm, memory, "rt_paint_layer_check_stays")
              asm.jsr(asm.abs("rt_paint_layer_demote")) # off the list, so the next is at the same place
              asm.brl("rt_paint_layer_check_text")
              asm.label("rt_paint_layer_check_stays")
              asm.inc(asm.abs(memory[LISTED]))
              asm.inc(asm.abs(memory[LISTED]))
              asm.brl("rt_paint_layer_check_text")
              asm.label("rt_paint_layer_check_done")
              1.downto(0) do |half|
                asm.pla
                asm.sta(asm.abs(hash + (half * 2)))
              end
              kept.reverse_each do |at|
                asm.pla
                asm.sta(asm.direct(at))
              end
              asm.ply
              asm.plx
              asm.rts
            end

            # rt_paint_layer_demote (JSR, the text at hand on the layer, while paintings are written
            # down): the text off the layer and painted instead, where it was drawn. Its entry in the
            # log becomes a picture painted there (KIND_DEMOTED); if the log was painted since and
            # the entry is gone, an entry for it is written down now, before the painting that takes
            # it off. Its tiles take its hash, as a painting's do. Uses the direct page's scratch.
            def emit_demote(asm, memory, s)
              log = memory[PaintLog::LOG]
              text = memory[TEXT]
              asm.label("rt_paint_layer_demote")
              asm.jsr(asm.abs("rt_paint_layer_remove"))
              asm.ldx(0)
              asm.label("rt_paint_layer_demote_find")
              asm.cpx(asm.abs(memory[PaintLog::LOG_END]))
              asm.bcs("rt_paint_layer_demote_written")
              asm.lda(asm.long_x(log))
              asm.cmp(PaintLog::KIND_LAYER)
              asm.bne("rt_paint_layer_demote_next")
              asm.lda(asm.long_x(log, PaintLog::ENTRY_NUMBERS))
              asm.cmp(asm.abs(text + T_NUMBER))
              asm.beq("rt_paint_layer_demote_found")
              asm.label("rt_paint_layer_demote_next")
              asm.txa
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.tax
              asm.bra("rt_paint_layer_demote_find")
              asm.label("rt_paint_layer_demote_found")
              asm.lda(PaintLog::KIND_DEMOTED)
              asm.sta(asm.long_x(log))
              asm.brl("rt_paint_layer_demote_mark")
              # X is the log's end: an entry of its own.
              asm.label("rt_paint_layer_demote_written")
              asm.lda(PaintLog::KIND_DEMOTED)
              asm.sta(asm.long_x(log))
              [0, 0, Paint::WIDTH, Paint::HEIGHT].each_with_index do |edge, i|
                asm.lda(edge)
                asm.sta(asm.long_x(log, PaintLog::ENTRY_AREA + (i * 2)))
              end
              [T_NUMBER, T_PICTURE, T_X, T_Y, nil].each_with_index do |from, i|
                if from
                  asm.lda(asm.abs(text + from))
                else
                  asm.lda(0)
                end
                asm.sta(asm.long_x(log, PaintLog::ENTRY_NUMBERS + (i * 4)))
                asm.lda(0)
                asm.sta(asm.long_x(log, PaintLog::ENTRY_NUMBERS + (i * 4) + 2))
              end
              emit_entry_tiles(asm, log, text)
              asm.txa
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.sta(asm.abs(memory[PaintLog::LOG_END]))
              asm.label("rt_paint_layer_demote_mark")
              2.times do |half|
                asm.lda(asm.abs(text + T_HASH + (half * 2)))
                asm.sta(asm.abs(memory[PaintLog::OP_HASH] + (half * 2)))
              end
              [[T_TOP, s.mark_row], [T_BOTTOM, s.temp], [T_FIRST, s.chunk], [T_LAST, s.last]].each do |from, to|
                asm.lda(asm.abs(text + from))
                asm.sta(asm.direct(to))
              end
              asm.jmp(asm.abs("rt_paint_mark_rows_checked"))
            end

            # rt_paint_layer_check_now (JSR, at the top of PaintLog's rt_paint_mark_now: a painting
            # done at once, rows of pixels +top+ up to +bottom+, columns +chunk+ to +last+): each text
            # on the layer whose tiles it covers taken off the layer and painted at once, first. The
            # direct page, the area and the painting's numbers PaintLog keeps are put back after.
            def emit_check_now(asm, memory, s)
              area = memory[Paint::AREA]
              kept = memory[KEPT_PAGE]
              row = memory[ROW]
              asm.label("rt_paint_layer_check_now")
              asm.lda(asm.abs(memory[COUNT]))
              asm.bne("rt_paint_layer_check_now_look")
              asm.rts
              asm.label("rt_paint_layer_check_now_look")
              asm.phx
              asm.phy
              emit_columns_mask(asm, memory, s.chunk, s.last)
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.abs(row))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              emit_rows_covered(asm, memory, asm.abs(row), "rt_paint_layer_check_now_covered", "rt_paint_layer_check_now")
              asm.ply
              asm.plx
              asm.rts
              asm.label("rt_paint_layer_check_now_covered")
              rect = memory[RECT]
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.abs(rect))
              asm.lda(asm.abs(row))
              asm.sta(asm.abs(rect + 2))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.abs(rect + 4))
              asm.lda(asm.direct(s.last))
              asm.sta(asm.abs(rect + 6))
              asm.phb
              asm.lda(0xFF)
              asm.ldx(0)
              asm.ldy(kept & 0xFFFF)
              asm.mvn(kept >> 16, 0x00)
              asm.plb
              Paint::AREA_WORDS.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.pha
              end
              [PaintLog::OP_KIND, PaintLog::OP_BYTES].each do |name|
                asm.lda(asm.abs(memory[name]))
                asm.pha
              end
              2.times do |half|
                asm.lda(asm.abs(memory[PaintLog::OP_HASH] + (half * 2)))
                asm.pha
              end
              # Each text the painting covers off the layer and painted, at once; the painting of
              # one finds the layer without it (and no other text there: theirs share no tile).
              asm.stz(asm.abs(memory[LISTED]))
              asm.label("rt_paint_layer_check_now_text")
              asm.lda(asm.abs(memory[COUNT]))
              asm.asl
              asm.cmp(asm.abs(memory[LISTED]))
              asm.beq("rt_paint_layer_check_now_painted")
              asm.branch_long(:bcc, "rt_paint_layer_check_now_painted")
              asm.ldx(asm.abs(memory[LISTED]))
              asm.lda(asm.abs_x(memory[PLACED]))
              asm.jsr(asm.abs("rt_paint_layer_find"))
              emit_unless_rect_shared(asm, memory, "rt_paint_layer_check_now_stays")
              asm.jsr(asm.abs("rt_paint_layer_remove"))
              text = memory[TEXT]
              [T_PICTURE, T_X, T_Y].each_with_index do |from, i|
                asm.lda(asm.abs(text + from))
                asm.sta(asm.direct(Paint::R.call(i)))
                asm.stz(asm.direct(Paint::R.call(i) + 2))
              end
              asm.jsl(asm.long("rt_paint_anywhere"))
              asm.jsl(asm.long("rt_paint_blit"))
              asm.brl("rt_paint_layer_check_now_text") # off the list, so the next is at the same place
              asm.label("rt_paint_layer_check_now_stays")
              asm.inc(asm.abs(memory[LISTED]))
              asm.inc(asm.abs(memory[LISTED]))
              asm.brl("rt_paint_layer_check_now_text")
              asm.label("rt_paint_layer_check_now_painted")
              1.downto(0) do |half|
                asm.pla
                asm.sta(asm.abs(memory[PaintLog::OP_HASH] + (half * 2)))
              end
              [PaintLog::OP_BYTES, PaintLog::OP_KIND].each do |name|
                asm.pla
                asm.sta(asm.abs(memory[name]))
              end
              (Paint::AREA_WORDS - 1).downto(0) do |i|
                asm.pla
                asm.sta(asm.abs(area + (i * 2)))
              end
              asm.phb
              asm.lda(0xFF)
              asm.ldx(kept & 0xFFFF)
              asm.ldy(0)
              asm.mvn(0x00, kept >> 16)
              asm.plb
              asm.ply
              asm.plx
              asm.rts
            end

            # rt_paint_layer_replace (JSR, X a text's entry in the log, in PaintLog's
            # rt_paint_apply_deferred_clear): the text on the layer again, its entry said to be so,
            # and A nought; or, where it cannot be (the layer full, or a text there already), its
            # entry said to be painted, and A not nought. Keeps X.
            def emit_replace(asm, memory)
              log = memory[PaintLog::LOG]
              asm.label("rt_paint_layer_replace")
              asm.phx
              asm.lda(asm.long_x(log, PaintLog::ENTRY_NUMBERS))
              asm.jsr(asm.abs("rt_paint_layer_find"))
              asm.lda(asm.abs(memory[COUNT]))
              asm.cmp(MOST_PLACED)
              asm.bcs("rt_paint_layer_replace_not")
              asm.jsr(asm.abs("rt_paint_layer_free"))
              asm.bne("rt_paint_layer_replace_not")
              asm.jsr(asm.abs("rt_paint_layer_place"))
              asm.plx
              asm.lda(PaintLog::KIND_LAYER)
              asm.sta(asm.long_x(log))
              asm.lda(0)
              asm.rts
              asm.label("rt_paint_layer_replace_not")
              asm.plx
              asm.lda(PaintLog::KIND_DEMOTED)
              asm.sta(asm.long_x(log))
              asm.rts
            end

            # rt_paint_layer_upload (JSR, in the blank, with the painted layer's map): the layer's map
            # from the first row that changed to the last, in one copy to video RAM.
            def emit_upload(asm, memory)
              h = Console::SNESHardware
              cells = memory[CELLS]
              asm.label("rt_paint_layer_upload")
              asm.lda(asm.abs(memory[CHANGED_BYTES]))
              asm.beq("rt_paint_layer_upload_done")
              asm.lda(asm.abs(memory[CHANGED_FIRST]))
              5.times { asm.asl } # 32 words a row
              asm.clc
              asm.adc(MAP)
              asm.sta(asm.abs(h::VMADDL))
              asm.lda(asm.abs(memory[CHANGED_FIRST]))
              asm.xba
              asm.lsr
              asm.lsr # 64 bytes a row
              asm.clc
              asm.adc(cells & 0xFFFF)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.lda(asm.abs(memory[CHANGED_BYTES]))
              asm.sec
              asm.sbc(Paint::RUN_SETTING_UP)
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(cells >> 16)
              Paint.emit_copy_to_video_ram(asm)
              emit_none_changed(asm, memory)
              asm.label("rt_paint_layer_upload_done")
              asm.rts
            end

            # The masks of columns from one to the last (rt_paint_layer_from_column) and from the
            # first up to one (rt_paint_layer_up_to_column), 32 bits each; and the byte an empty
            # cell is twice.
            def emit_tables(asm)
              all = 0xFFFF_FFFF
              asm.label("rt_paint_layer_from_column")
              Paint::COLUMNS.times { |column| asm.data_words((all << column) & 0xFFFF, ((all << column) & all) >> 16) }
              asm.label("rt_paint_layer_up_to_column")
              Paint::COLUMNS.times do |column|
                mask = (1 << (column + 1)) - 1
                asm.data_words(mask & 0xFFFF, mask >> 16)
              end
              asm.label("rt_paint_layer_empty_byte")
              asm.data_bytes(TextLayerArt::EMPTY_CELL & 0xFF)
            end
          end
        end
      end
    end
  end
end
