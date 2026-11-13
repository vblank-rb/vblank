# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN OF BIG PIXELS (`screen :bitmap, pixel_size: 2`): the game paints a
          # picture 128 pixels across and 112 down, and the console shows each of its pixels as a
          # square of four, filling its 256×224 screen.
          #
          # Paint's screen is Mode 3's tiles, whose pixels are kept in PLANES: a pixel's colour is
          # eight bits spread over eight bytes of its tile. Painting one means changing eight bytes,
          # and a picture copied to video RAM is 64 bytes a tile however little of it changed. Mode 7
          # (BGMODE 7) keeps its tiles another way, ONE BYTE A PIXEL: a tile is 64 bytes, its rows
          # top to bottom and each row left to right, and a byte is a place in the colour memory, as
          # Paint's are (SNES::PaintedArt picks them). So a pixel painted is a byte written.
          #
          # Mode 7 shows one layer, and turns and resizes it with a MATRIX (M7A to M7D, 8.8 fixed
          # point): the console's pixel (x, y) shows the layer's pixel (A·x + B·y, C·x + D·y). With A
          # and D at $0080, a half, and B and C at nought, each step across the screen is half a
          # pixel of the layer, so each of the layer's pixels fills a square of four (fullsnes,
          # "SNES PPU Rotation/Scaling"). The console's own games used the same registers to show a
          # small picture at twice its size.
          #
          # VIDEO RAM. Mode 7 reads its layer from the first 32K words of video RAM: the low byte of
          # each word is a cell of its map, 128 cells across and 128 down, and the high byte of each
          # word is a byte of its tiles, 256 tiles of 64 bytes. The picture is 16 tiles across and 14
          # down, 224 tiles, numbered in rows, and the map's top left 16×14 cells name them in that
          # order. The rest of the map is never shown: the screen ends at the picture's edges.
          #
          #   word $0000 + tile × 64 + row × 8 + column   (high byte)  a pixel of a tile
          #   word $0000 + cell row × 128 + cell column   (low byte)   a cell of the map
          #
          # THE GAME PAINTS INTO A COPY in work RAM, COPY_BYTES in the last bank, laid out as video RAM
          # keeps the tiles: so the pixel (x, y) is the byte
          #
          #   (y ÷ 8) × 1024 + (x ÷ 8) × 64 + (y mod 8) × 8 + (x mod 8)
          #
          # which is bits of x and y put side by side (rt_paint_doubled_at), and a row of tiles is
          # 1024 bytes one after another. As it paints it marks the rows of tiles it changed (DIRTY),
          # and after the pass those rows go to video RAM in one piece: the same places in the copy
          # and in video RAM, so the copy is a single run however many tiles of the rows changed.
          # The copy writes the high bytes alone (VMAIN increments after the high byte, and the
          # copying engine writes VMDATAH), one word of video RAM for each byte.
          #
          # THE COPY TO VIDEO RAM IS SPREAD OVER BLANKS, WITH THE SCREEN ON, as Paint's is (Blank says
          # how), as many bytes at a time as the blank has room for. A picture that changes all 14
          # rows of tiles is 14336 bytes: the blank's room alone takes three, and with rows given up
          # (`shown_rows:`, Letterbox) the lines switched off are the copy's too. The game's pass
          # waits until the copy has arrived, so it never paints over a picture still being sent;
          # but there is one picture in video RAM, not two, so a change bigger than one blank (or
          # one window) holds is seen arriving down the screen, as Paint's tiles painted in both
          # passes are.
          #
          # A CLEAR OF THE WHOLE SCREEN is the copying engine filling the copy with one byte, a
          # fixed source sent to work RAM's port, a byte a slow cycle; a clear of a part of it is a
          # fill. A fill across the whole width is the same copy for its whole rows of tiles
          # (emit_fill_band), and otherwise writes four words for every eight pixels of a tile's row
          # that it covers whole.
          #
          # What Paint does that this does not do yet is refused by name as the game is built
          # (Lowering::Picture#refuse_unmade_doubled_screen!): the patch under a sprite, a column of a
          # picture drawn stretched, and a Super FX cartridge. The camera is refused for big pixels on
          # every console (Guardrails::Checks::BiggerPixelsNotMadeYet).
          #
          #   rt_paint_start         at power-on: Mode 7, its matrix, the map, the colours
          #   rt_paint_area          what follows paints only inside a rectangle (`inside`)
          #   rt_paint_anywhere      the whole screen to paint in
          #   rt_paint_clear         the screen, or the area, in one colour
          #   rt_paint_fill          a rectangle in one colour
          #   rt_paint_blit          a picture at a place (Lowering::Paint#doubled_picture_sections)
          #   rt_paint_blit_one_of   one of a list of pictures, by number
          #   rt_paint_prepare       as a pass ends: nothing, the rows changed are already marked
          #   rt_paint_upload        in the blank (JSR): the rows changed, then the colours
          module PaintDoubled
            PIXEL_SIZE = 2
            WIDTH = Paint::WIDTH / PIXEL_SIZE
            HEIGHT = Paint::HEIGHT / PIXEL_SIZE
            COLUMNS = WIDTH / 8
            ROWS = HEIGHT / 8
            TILE_BYTES = 64
            ROW_BYTES = COLUMNS * TILE_BYTES
            COPY_BYTES = ROWS * ROW_BYTES
            COPY = "rt paint doubled copy"
            # The map's cells across, and what BGMODE is told.
            MAP_ACROSS = 128
            MODE_7 = 0x07
            # M7SEL: outside the layer's 1024×1024 pixels, nothing is drawn (the backdrop shows).
            OUTSIDE_SEE_THROUGH = 0x80
            # A half, in the matrix's 8.8 fixed point.
            HALF_STEP = 0x0080
            # The layer scrolled up one, as Paint's is: the screen's first row is the console's line
            # 1. Mode 7's scroll is 13 bits.
            ONE_UP = 0x1FFF
            # The first row of tiles changed since the last copy, and the one past the last. None:
            # ROWS and nought.
            DIRTY_FIRST = "rt paint doubled dirty first"
            DIRTY_END = "rt paint doubled dirty end"
            # How far a picture's place can be off the screen and still be painted, as Paint's is: a
            # place is held as a number of 16 bits with this added, so it is never below nought.
            NEAR = 2048
            # What setting a piece of the copy going costs the blank, counted as bytes (Paint's).
            PIECE_SETTING_UP = Paint::RUN_SETTING_UP
            # The fewest bytes a blank is asked to take: less than this waits for the next blank.
            FEWEST_PIECE_BYTES = 64
            # The bytes of the whole colour memory, sent after the picture when a fade or tint changed it.
            COLOR_BYTES = 512
            # What a fill keeps as its band's first row when it has no band of whole rows of tiles
            # (emit_fill_band): no pixel row.
            NO_BAND = 0xFFFF

            R = Paint::R

            module_function

            def reserve(memory)
              copy = memory.reserve_last_bank(COPY, COPY_BYTES)
              # The copy's bytes are counted in 16 bits from its start (rt_paint_doubled_at).
              raise LoweringError, "the copy of the screen must not cross a bank of work RAM" if (copy & 0xFFFF) + COPY_BYTES > 0x10000

              memory.reserve(Paint::AREA, Paint::AREA_WORDS * 2)
              memory.reserve(DIRTY_FIRST, 2)
              memory.reserve(DIRTY_END, 2)
            end

            def kept?(memory) = memory.reserved?(COPY)

            # +s+ is Paint's scratch (Paint.scratch): the same direct page, used here as named below.
            # +band+ is the console's first and last line shown (Letterbox.band_of), or nil for all.
            def emit(asm, memory, s, band: nil)
              emit_start(asm, memory)
              Paint.emit_area(asm, memory, s, width: WIDTH, height: HEIGHT)
              emit_helpers(asm, memory, s)
              emit_clear(asm, memory, s)
              emit_fill(asm, memory, s)
              emit_blit(asm, memory, s)
              asm.label("rt_paint_prepare")
              asm.rtl
              emit_upload(asm, memory, s, tile_rows_shown(band))
              emit_tables(asm)
            end

            # The rows of tiles the console shows any line of, [first, past]: a row of tiles is
            # eight of the game's rows, each PIXEL_SIZE of the console's lines, and the screen's row
            # y is the console's line y + 1. Rows given up (`shown_rows:`) are never copied: they are
            # black whatever the copy holds.
            def tile_rows_shown(band)
              return [0, ROWS] unless band

              first, last = band
              lines_a_row = 8 * PIXEL_SIZE
              [(first - 1) / lines_a_row, (last + lines_a_row - 1) / lines_a_row]
            end

            # --- power-on ---

            def emit_start(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_paint_start")
              asm.sep(0x20)
              asm.lda(MODE_7)
              asm.sta(asm.abs(h::BGMODE))
              asm.lda(OUTSIDE_SEE_THROUGH)
              asm.sta(asm.abs(h::M7SEL))
              # The matrix, each register written twice, its low byte and then its high: A and D a
              # half, B and C nought, as Boot leaves them, and the middle it turns round (M7X and
              # M7Y) at nought.
              [h::M7A, h::M7D].each do |register|
                asm.lda(HALF_STEP & 0xFF)
                asm.sta(asm.abs(register))
                asm.lda(HALF_STEP >> 8)
                asm.sta(asm.abs(register))
              end
              asm.lda(ONE_UP & 0xFF)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.lda(ONE_UP >> 8)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.lda(0x01) # the layer alone on the main screen
              asm.sta(asm.abs(h::TM))
              # The map: its low bytes alone, so the address moves on after each low byte.
              asm.stz(asm.abs(h::VMAIN))
              asm.rep(0x20)
              asm.ldx(0)
              asm.label("rt_paint_doubled_start_row")
              asm.txa # the tile's number, 16 a row, is the row × 16: the row's cells are at row × 128
              3.times { asm.asl }
              asm.sta(asm.abs(h::VMADDL))
              asm.label("rt_paint_doubled_start_cell")
              asm.sep(0x20)
              asm.txa
              asm.sta(asm.abs(h::VMDATAL))
              asm.rep(0x20)
              asm.inx
              asm.txa
              asm.and_a(COLUMNS - 1)
              asm.bne("rt_paint_doubled_start_cell")
              asm.cpx(COLUMNS * ROWS)
              asm.bne("rt_paint_doubled_start_row")
              # Every other copy writes the tiles, the high bytes.
              asm.sep(0x20)
              asm.lda(0x80)
              asm.sta(asm.abs(h::VMAIN))
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              # The colours, all 256, and where they change as the game runs, there too.
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              asm.jsl(asm.long("rt_colors_start")) if memory.reserved?(Tint::COLORS_NOW)
              # Paint anywhere, and nothing changed yet. The copy and video RAM start all nought,
              # place 0, black, as Boot leaves them.
              asm.jsl(asm.long("rt_paint_anywhere"))
              emit_none_dirty(asm, memory)
              Letterbox.emit_start(asm, memory) if Letterbox.kept?(memory)
              asm.rtl
            end

            def emit_none_dirty(asm, memory)
              asm.lda(ROWS)
              asm.sta(asm.abs(memory[DIRTY_FIRST]))
              asm.stz(asm.abs(memory[DIRTY_END]))
            end

            # --- helpers ---

            # rt_paint_take_area: the area into the direct page (s.area).
            # rt_paint_doubled_at: A = the copy's byte for the pixel (s.column, s.last).
            # rt_paint_doubled_mark: the rows of tiles from pixel row s.mark_row to before
            #   s.mark_count (one or more) marked changed.
            # rt_paint_doubled_fill_row: s.count pixels (one or more) from the copy's byte X, the
            #   colour's place in both bytes of s.mask; X moves on past them.
            def emit_helpers(asm, memory, s)
              copy = memory[COPY]
              area = memory[Paint::AREA]
              asm.label("rt_paint_take_area")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.direct(s.area + (i * 2)))
              end
              asm.rts

              asm.label("rt_paint_doubled_at")
              asm.lda(asm.direct(s.last))
              asm.and_a(0xFFF8)
              7.times { asm.asl }
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.last))
              asm.and_a(0x0007)
              3.times { asm.asl }
              asm.ora(asm.direct(s.tile))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.column))
              asm.and_a(0xFFF8)
              3.times { asm.asl }
              asm.ora(asm.direct(s.tile))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.column))
              asm.and_a(0x0007)
              asm.ora(asm.direct(s.tile))
              asm.rts

              asm.label("rt_paint_doubled_mark")
              asm.lda(asm.direct(s.mark_row))
              3.times { asm.lsr }
              asm.cmp(asm.abs(memory[DIRTY_FIRST]))
              asm.bcs("rt_paint_doubled_mark_first_kept")
              asm.sta(asm.abs(memory[DIRTY_FIRST]))
              asm.label("rt_paint_doubled_mark_first_kept")
              asm.lda(asm.direct(s.mark_count))
              asm.dec
              3.times { asm.lsr }
              asm.inc
              asm.cmp(asm.abs(memory[DIRTY_END]))
              asm.bcc("rt_paint_doubled_mark_end_kept")
              asm.sta(asm.abs(memory[DIRTY_END]))
              asm.label("rt_paint_doubled_mark_end_kept")
              asm.rts

              # A tile's row is eight bytes one after another, and the next tile across is 64 bytes
              # on from a row's start: from the row's last byte, 57.
              asm.label("rt_paint_doubled_fill_row")
              asm.txa
              asm.and_a(0x0007)
              asm.bne("rt_paint_doubled_fill_byte")
              asm.lda(asm.direct(s.count))
              asm.cmp(8)
              asm.bcc("rt_paint_doubled_fill_byte")
              asm.lda(asm.direct(s.mask))
              4.times { |word| asm.sta(asm.long_x(copy, word * 2)) }
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              asm.lda(asm.direct(s.count))
              asm.sec
              asm.sbc(8)
              asm.sta(asm.direct(s.count))
              asm.bne("rt_paint_doubled_fill_row")
              asm.rts
              asm.label("rt_paint_doubled_fill_byte")
              asm.sep(0x20)
              asm.lda(asm.direct(s.mask))
              asm.sta(asm.long_x(copy))
              asm.rep(0x20)
              emit_next_byte(asm, "rt_paint_doubled_fill")
              asm.dec(asm.direct(s.count))
              asm.bne("rt_paint_doubled_fill_row")
              asm.rts
            end

            # X on from a pixel's byte to the next pixel across's: the next byte, or from a tile's
            # row's last byte the next tile's.
            def emit_next_byte(asm, prefix)
              asm.txa
              asm.and_a(0x0007)
              asm.cmp(0x0007)
              asm.beq("#{prefix}_next_tile")
              asm.inx
              asm.bra("#{prefix}_moved")
              asm.label("#{prefix}_next_tile")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES - 7)
              asm.tax
              asm.label("#{prefix}_moved")
            end

            # --- clear and fill ---

            # rt_paint_clear(place): the area, or with the whole screen to paint in, the whole copy
            # filled by the copying engine with the byte at "rt paint doubled places" + place.
            def emit_clear(asm, memory, s)
              asm.label("rt_paint_clear")
              asm.jsr(asm.abs("rt_paint_take_area"))
              asm.lda(asm.direct(s.area_left))
              asm.ora(asm.direct(s.area_top))
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_right))
              asm.cmp(WIDTH)
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_bottom))
              asm.cmp(HEIGHT)
              asm.beq("rt_paint_clear_whole")
              asm.label("rt_paint_clear_area")
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(R.call(4)))
              [[s.area_left, nil, R.call(0)], [s.area_top, nil, R.call(1)],
               [s.area_right, s.area_left, R.call(2)], [s.area_bottom, s.area_top, R.call(3)]].each do |from, less, out|
                asm.lda(asm.direct(from))
                if less
                  asm.sec
                  asm.sbc(asm.direct(less))
                end
                asm.sta(asm.direct(out))
                asm.stz(asm.direct(out + 2))
              end
              asm.brl("rt_paint_fill")

              asm.label("rt_paint_clear_whole")
              asm.lda(COPY_BYTES)
              asm.sta(asm.direct(s.chunk))
              asm.lda(0)
              emit_copy_filled(asm, memory, s, R.call(0))
              asm.stz(asm.abs(memory[DIRTY_FIRST]))
              asm.lda(ROWS)
              asm.sta(asm.abs(memory[DIRTY_END]))
              asm.rtl
            end

            # rt_paint_fill(x, y, w, h, place): the rectangle, inside the area.
            def emit_fill(asm, memory, s)
              asm.label("rt_paint_fill")
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[R.call(0), R.call(2), R.call(5)], [R.call(1), R.call(3), R.call(6)]].each do |at, size, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              Paint.emit_clamp(asm, "doubled fill", R.call(0), s.area_left, s.area_right, s.left)
              Paint.emit_clamp(asm, "doubled fill", R.call(5), s.area_left, s.area_right, s.right)
              Paint.emit_clamp(asm, "doubled fill", R.call(1), s.area_top, s.area_bottom, s.top)
              Paint.emit_clamp(asm, "doubled fill", R.call(6), s.area_top, s.area_bottom, s.bottom)
              asm.lda(asm.direct(s.left))
              asm.cmp(asm.direct(s.right))
              asm.bcs("rt_paint_fill_none")
              asm.lda(asm.direct(s.top))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_fill_some")
              asm.label("rt_paint_fill_none")
              asm.rtl
              asm.label("rt_paint_fill_some")
              asm.sta(asm.direct(s.mark_row))
              asm.lda(asm.direct(s.bottom))
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_doubled_mark"))
              # The colour's place in both bytes.
              asm.lda(asm.direct(R.call(4)))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(s.mask))
              asm.xba
              asm.ora(asm.direct(s.mask))
              asm.sta(asm.direct(s.mask))
              emit_fill_band(asm, memory, s)
              asm.lda(asm.direct(s.left))
              asm.sta(asm.direct(s.column))
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.last))
              asm.label("rt_paint_fill_row")
              asm.lda(asm.direct(s.last))
              asm.cmp(asm.direct(s.first_x))
              asm.bne("rt_paint_fill_row_go")
              asm.lda(asm.direct(s.across))
              asm.sta(asm.direct(s.last))
              asm.label("rt_paint_fill_row_go")
              asm.cmp(asm.direct(s.bottom))
              asm.bcs("rt_paint_fill_done")
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.tax
              asm.lda(asm.direct(s.right))
              asm.sec
              asm.sbc(asm.direct(s.left))
              asm.sta(asm.direct(s.count))
              asm.jsr(asm.abs("rt_paint_doubled_fill_row"))
              asm.inc(asm.direct(s.last))
              asm.bra("rt_paint_fill_row")
              asm.label("rt_paint_fill_done")
              asm.rtl
            end

            # A FILL ACROSS THE WHOLE SCREEN covers every row of tiles from its first whole one to
            # its last whole one throughout, and those are bytes one after another in the copy (a row
            # of tiles is 1024 of them), so the copying engine fills them as a clear does: a floor or a
            # ceiling is one copy. The band's first pixel row and the row past it are left where the
            # row loop reads them (#band_rows), which passes over them; with no band, NO_BAND, which
            # no row is.
            def emit_fill_band(asm, memory, s)
              band_first, band_end = band_rows(s)
              asm.lda(NO_BAND)
              asm.sta(asm.direct(band_first))
              asm.lda(asm.direct(s.left))
              asm.bne("rt_paint_fill_band_none")
              asm.lda(asm.direct(s.right))
              asm.cmp(WIDTH)
              asm.bne("rt_paint_fill_band_none")
              asm.lda(asm.direct(s.bottom))
              asm.and_a(0xFFF8)
              asm.sta(asm.direct(band_end))
              asm.lda(asm.direct(s.top))
              asm.clc
              asm.adc(7)
              asm.and_a(0xFFF8)
              asm.cmp(asm.direct(band_end))
              asm.bcs("rt_paint_fill_band_none")
              asm.sta(asm.direct(band_first))
              asm.lda(asm.direct(band_end))
              asm.sec
              asm.sbc(asm.direct(band_first))
              7.times { asm.asl } # a pixel row of whole tiles is 128 bytes
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(band_first))
              7.times { asm.asl }
              emit_copy_filled(asm, memory, s, R.call(4))
              asm.label("rt_paint_fill_band_none")
            end

            # The direct page a fill keeps its band of whole rows of tiles in (#emit_fill_band):
            # Paint's scratch, under names of their own here.
            def band_rows(s) = [s.first_x, s.across]

            # s.chunk bytes of the copy from its byte A filled with the place at +place+ (a working
            # number), by the copying engine sending one byte of "rt paint doubled places" over and
            # over to work RAM's port. A is not kept.
            def emit_copy_filled(asm, memory, s, place)
              h = Console::SNESHardware
              offset = memory[COPY] - Picture::WORK_RAM
              asm.clc
              asm.adc(offset & 0xFFFF)
              asm.sta(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.lda(offset >> 16)
              asm.sta(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              asm.lda(asm.direct(place))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.imm("rt paint doubled places"))
              asm.clc
              asm.adc(asm.direct(s.temp))
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.chunk))
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT | h::DMA_FIXED_SOURCE, h::WMDATA, asm.direct(s.temp),
                               asm.bank_of("rt paint doubled places"), nil)
            end

            # --- pictures ---

            # rt_paint_blit_one_of(list, index, x, y): picture +index+ of the list, or none for an
            # index past it. rt_paint_blit(number, x, y): the picture, inside the area.
            #
            # A picture is "paint pictures"' entry +number+: where its rows are, its width and its
            # height. Each row is its RUNS of pixels drawn, each a word of how many, a word of how far
            # from the picture's left edge, and a byte for each pixel, its colour's place; a run of
            # none ends the row. So a see-through pixel costs nothing, and a run is cut to the area
            # once, not a pixel at a time.
            #
            # Places are held as 16-bit numbers with NEAR added, which every place painted at all
            # fits, so they compare unsigned. On the direct page: s.across the picture's left,
            # s.row the row at hand, s.left to s.bottom the area, all with NEAR; s.height the rows
            # left; s.count a run's pixels; s.shift a run's left; s.chunk and s.not_mask the part
            # of it in the area; s.run where the next run starts.
            def emit_blit(asm, memory, s)
              copy = memory[COPY]
              asm.label("rt_paint_blit_one_of")
              asm.lda(asm.direct(R.call(0)))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("paint picture lists"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint picture lists", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.direct(R.call(1) + 2))
              asm.branch_long(:bne, "rt_paint_blit_none")
              asm.lda(asm.direct(R.call(1)))
              asm.cmp(asm.ind_long(s.pointer))
              asm.branch_long(:bcs, "rt_paint_blit_none")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(R.call(0)))
              [[2, 1], [3, 2]].each do |from, to|
                asm.lda(asm.direct(R.call(from)))
                asm.sta(asm.direct(R.call(to)))
                asm.lda(asm.direct(R.call(from) + 2))
                asm.sta(asm.direct(R.call(to) + 2))
              end

              asm.label("rt_paint_blit")
              [[R.call(1), WIDTH, s.across], [R.call(2), HEIGHT, s.row]].each do |at, edge, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(NEAR)
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(0)
                asm.branch_long(:bne, "rt_paint_blit_none")
                asm.lda(asm.direct(out))
                asm.cmp(NEAR + edge)
                asm.branch_long(:bcs, "rt_paint_blit_none")
              end
              asm.lda(asm.direct(R.call(0)))
              3.times { asm.asl }
              asm.tax
              asm.lda(asm.long_x("paint pictures"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint pictures", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.long_x("paint pictures", 6))
              asm.branch_long(:beq, "rt_paint_blit_none")
              asm.sta(asm.direct(s.height))
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[s.area_left, s.left], [s.area_top, s.top], [s.area_right, s.right], [s.area_bottom, s.bottom]].each do |from, out|
                asm.lda(asm.direct(from))
                asm.clc
                asm.adc(NEAR)
                asm.sta(asm.direct(out))
              end
              # The rows marked changed: the picture's, inside the area.
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.top))
              asm.bcs("rt_paint_blit_mark_top")
              asm.lda(asm.direct(s.top))
              asm.label("rt_paint_blit_mark_top")
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(s.mark_row))
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_blit_mark_bottom")
              asm.lda(asm.direct(s.bottom))
              asm.label("rt_paint_blit_mark_bottom")
              asm.sec
              asm.sbc(NEAR)
              asm.cmp(asm.direct(s.mark_row))
              asm.beq("rt_paint_blit_rows")
              asm.bcc("rt_paint_blit_rows")
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_doubled_mark"))

              asm.label("rt_paint_blit_rows")
              asm.ldy(0)
              asm.label("rt_paint_blit_run")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.branch_long(:beq, "rt_paint_blit_row_end")
              asm.sta(asm.direct(s.count))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.pointer))
              asm.iny
              asm.iny
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.sta(asm.direct(s.shift))
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.sta(asm.direct(s.run))
              # A row outside the area paints nothing; its runs are passed over.
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.top))
              asm.bcc("rt_paint_blit_run_done")
              asm.cmp(asm.direct(s.bottom))
              asm.bcs("rt_paint_blit_run_done")
              # The run cut to the area: from the later of its left and the area's, to the earlier
              # of its right and the area's.
              asm.lda(asm.direct(s.shift))
              asm.cmp(asm.direct(s.left))
              asm.bcs("rt_paint_blit_run_left")
              asm.lda(asm.direct(s.left))
              asm.label("rt_paint_blit_run_left")
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.shift))
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.cmp(asm.direct(s.right))
              asm.bcc("rt_paint_blit_run_right")
              asm.lda(asm.direct(s.right))
              asm.label("rt_paint_blit_run_right")
              asm.sta(asm.direct(s.not_mask))
              asm.cmp(asm.direct(s.chunk))
              asm.beq("rt_paint_blit_run_done")
              asm.bcc("rt_paint_blit_run_done")
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              # Its first pixel's byte in the picture, and in the copy.
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sec
              asm.sbc(asm.direct(s.shift))
              asm.tay
              asm.lda(asm.direct(s.chunk))
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(s.column))
              asm.lda(asm.direct(s.row))
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(s.last))
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.tax
              asm.label("rt_paint_blit_pixel")
              asm.sep(0x20)
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.long_x(copy))
              asm.rep(0x20)
              asm.iny
              emit_next_byte(asm, "rt_paint_blit_pixel")
              asm.dec(asm.direct(s.count))
              asm.bne("rt_paint_blit_pixel")
              asm.label("rt_paint_blit_run_done")
              asm.ldy(asm.direct(s.run))
              asm.brl("rt_paint_blit_run")
              asm.label("rt_paint_blit_row_end")
              asm.iny
              asm.iny
              asm.inc(asm.direct(s.row))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_blit_run")
              asm.label("rt_paint_blit_none")
              asm.rtl
            end

            # --- the copy to video RAM ---

            # rt_paint_upload (JSR, from Picture's rt_upload_copy): the rows of tiles changed, as many
            # bytes at a time as the blank has room for, and then the colours if a fade or tint changed
            # them, in a blank with room for all 512 bytes. Only the rows of tiles +shown+ are sent.
            def emit_upload(asm, memory, s, shown)
              h = Console::SNESHardware
              copy = memory[COPY]
              tint = memory[Tint::STATE]
              first, past = shown
              asm.label("rt_paint_upload")
              asm.lda(asm.abs(memory[DIRTY_END]))
              if past < ROWS
                asm.cmp(past)
                asm.bcc("rt_paint_upload_end_shown")
                asm.lda(past)
                asm.label("rt_paint_upload_end_shown")
              end
              asm.sta(asm.direct(s.last))
              asm.lda(asm.abs(memory[DIRTY_FIRST]))
              if first.positive?
                asm.cmp(first)
                asm.bcs("rt_paint_upload_first_shown")
                asm.lda(first)
                asm.label("rt_paint_upload_first_shown")
              end
              asm.cmp(asm.direct(s.last))
              asm.branch_long(:bcs, "rt_paint_upload_nothing")
              # The first row's byte, which is its word in video RAM too, and the bytes to send: a row
              # of tiles is 1024 of each.
              10.times { asm.asl }
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.direct(s.last))
              10.times { asm.asl }
              asm.sec
              asm.sbc(asm.direct(s.pointer))
              asm.sta(asm.direct(s.count))
              emit_none_dirty(asm, memory)
              asm.label("rt_paint_upload_piece")
              asm.jsr(asm.abs("rt_blank_left"))
              asm.sec
              asm.sbc(PIECE_SETTING_UP)
              asm.bcc("rt_paint_upload_wait")
              asm.cmp(FEWEST_PIECE_BYTES)
              asm.bcc("rt_paint_upload_wait")
              asm.cmp(asm.direct(s.count))
              asm.bcc("rt_paint_upload_room")
              asm.lda(asm.direct(s.count))
              asm.label("rt_paint_upload_room")
              asm.sta(asm.direct(s.chunk))
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.lda(asm.direct(s.pointer))
              asm.sta(asm.abs(h::VMADDL))
              asm.clc
              asm.adc(copy & 0xFFFF)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              # The rest of the channel set for each piece, since the colours' copies and the sound's
              # between blanks use the same channel.
              asm.sep(0x20)
              asm.lda(0x80)
              asm.sta(asm.abs(h::VMAIN))
              asm.lda(copy >> 16)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_ONE_PORT)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAH & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.lda(asm.direct(s.pointer))
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.direct(s.count))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              asm.bne("rt_paint_upload_piece")
              asm.bra("rt_paint_upload_colors")
              asm.label("rt_paint_upload_wait")
              asm.jsr(asm.abs("rt_blank_next"))
              asm.bra("rt_paint_upload_piece")

              asm.label("rt_paint_upload_nothing")
              emit_none_dirty(asm, memory)
              asm.label("rt_paint_upload_colors")
              asm.lda(asm.abs(tint + Tint::CHANGED))
              asm.cmp(Tint::TO_SEND)
              asm.bne("rt_paint_upload_done")
              asm.lda(COLOR_BYTES)
              asm.jsr(asm.abs("rt_blank_room"))
              asm.jsr(asm.abs("rt_tint_upload"))
              asm.label("rt_paint_upload_done")
              asm.rts
            end

            # Every byte from 0 to 255, for a clear to send one of over and over.
            def emit_tables(asm)
              asm.label("rt paint doubled places")
              asm.data_bytes((0..255).to_a)
            end
          end
        end
      end
    end
  end
end
