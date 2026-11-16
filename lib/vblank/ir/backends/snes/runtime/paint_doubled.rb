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
          # down, 224 tiles, numbered DOWN EACH COLUMN OF TILES: the 14 tiles of the first column of
          # tiles are 0 to 13, the next column's 14 to 27, and so on, and the map's top left 16×14
          # cells name them so. The rest of the map is never shown: the screen ends at the picture's
          # edges.
          #
          #   word $0000 + tile × 64 + row × 8 + column   (high byte)  a pixel of a tile
          #   word $0000 + cell row × 128 + cell column   (low byte)   a cell of the map
          #
          # THE GAME PAINTS INTO A COPY in work RAM, in the last bank, laid out as video RAM keeps the
          # tiles (Layout). With the tiles numbered down each column, a column of tiles is 896 bytes
          # one after another, and inside it the pixel below any pixel is always 8 bytes on, tile or
          # no tile. So the pixel (x, y) is the byte
          #
          #   (x ÷ 8) × 896 + y × 8 + (x mod 8)
          #
          # (rt_paint_doubled_at), and a column of the picture is a byte every 8, all the way down.
          # That is what lets a wall's column be drawn by code made for its height that writes a
          # byte a row and works nothing out (#scaler_sections), as the console's own 3D games did.
          #
          # As the game paints it marks, for each column of tiles, the first and last pixel row it
          # changed (DIRTY_TOP, DIRTY_BOTTOM). After the pass those rows of each column of tiles go
          # to video RAM: the same places in the copy and in video RAM, and a column of tiles changed
          # from top to bottom runs on into the next, so a whole picture is a single run.
          # The copy writes the high bytes alone (VMAIN increments after the high byte, and the
          # copying engine writes VMDATAH), one word of video RAM for each byte.
          #
          # THE COPY TO VIDEO RAM IS SPREAD OVER BLANKS, WITH THE SCREEN ON, as Paint's is (see
          # Blank), as many bytes at a time as the blank has room for: a picture that changes all of
          # its 14336 bytes takes three blanks. Where nothing must arrive after it, there are two
          # copies, and the next pass paints one while the other is sent (see
          # PaintDoubledSend); otherwise the pass waits until the copy has arrived, so it never paints over a
          # picture still being sent. There is one picture in video RAM, not two, so a change
          # bigger than one blank (or one window) holds is seen arriving across the screen, as
          # Paint's tiles painted in both passes are.
          #
          # A CLEAR OF THE WHOLE SCREEN is the copying engine filling the copy with one byte, a
          # fixed source sent to work RAM's port, a byte a slow cycle. A fill covering a column of
          # tiles from side to side is the same copy for the rows it covers, which are bytes one
          # after another there, so a floor or a ceiling is one copy for each column of tiles; the
          # columns it covers only part of are written a byte at a time.
          #
          # A Super FX cartridge is refused, saying why, as the game is built
          # (Lowering::Picture#refuse_unmade_doubled_screen!). The camera is refused for big pixels
          # on every console (Guardrails::Checks::BiggerPixelsNotMadeYet).
          #
          #   rt_paint_start         at power-on: Mode 7, its matrix, the map, the colours
          #   rt_paint_area          what follows paints only inside a rectangle (`inside`)
          #   rt_paint_anywhere      the whole screen to paint in
          #   rt_paint_clear         the screen, or the area, in one colour
          #   rt_paint_fill          a rectangle in one colour
          #   rt_paint_blit          a picture at a place (Lowering::Paint#doubled_picture_sections)
          #   rt_paint_blit_one_of   one of a list of pictures, by number
          #   rt_paint_column        a column of a picture, stretched (`draw_column_at`)
          #   rt_paint_save          the patch of the screen under a sprite, kept
          #   rt_paint_restore       the patch put back
          #   rt_paint_prepare       as a pass ends: nothing, the rows changed are already marked
          #   rt_paint_upload        in the blank (JSR): the rows changed, then the colours
          #                          (PaintDoubledSend)
          module PaintDoubled
            PIXEL_SIZE = 2
            WIDTH = Paint::WIDTH / PIXEL_SIZE
            HEIGHT = Paint::HEIGHT / PIXEL_SIZE
            COLUMNS = WIDTH / 8
            ROWS = HEIGHT / 8
            TILE_BYTES = 64
            # From a pixel's byte to the byte of the pixel below it.
            ROW_STEP = 8
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
            # For each column of tiles, a word: the first pixel row changed since the last copy, and
            # the one past the last. None: HEIGHT and nought.
            DIRTY_TOP = "rt paint doubled dirty top"
            DIRTY_BOTTOM = "rt paint doubled dirty bottom"
            # What rt_paint_doubled_mark keeps as it goes: the last column of tiles it marks (two
            # bytes a column), and whether it marks for a fill (PaintDoubledSend#emit_stale_rows_copied_for_mark).
            MARK_LAST = "rt paint doubled mark last"
            MARK_FILLED = "rt paint doubled mark filled"
            # How far a picture's place can be off the screen and still be painted, as Paint's is: a
            # place is held as a number of 16 bits with this added, so it is never below nought.
            NEAR = 2048
            # What setting a piece of the copy going costs the blank, counted as bytes (Paint's).
            PIECE_SETTING_UP = Paint::RUN_SETTING_UP
            # The fewest bytes a blank is asked to take: less than this waits for the next blank.
            FEWEST_PIECE_BYTES = 64
            # The bytes of the whole colour memory, sent after the picture when a fade or tint changed it.
            COLOR_BYTES = 512

            # A COLUMN OF A PICTURE (rt_paint_column) is read from a record the lowering keeps for
            # each picture drawn so (Lowering::Paint#doubled_column_sections): the picture's width
            # and height (a word each); where the table of the step down the picture for each height
            # is (a long address and a spare byte); where the code for each height from nought to
            # HEIGHT is (#scaler_sections, four bytes each); and where each of its columns' places
            # start, four bytes each, the last 1 for a column with see-through pixels.
            RECORD_WIDTH = 0
            RECORD_HEIGHT = 2
            RECORD_STEPS = 4
            RECORD_SCALERS = 8
            RECORD_STARTS = RECORD_SCALERS + ((HEIGHT + 1) * 4)
            # The heights whose step down the picture is in the table the record names: a taller
            # column's is worked out as it is drawn, as a division of 32 bits is a routine of a bit
            # at a time.
            STEP_TABLE_HEIGHTS = 512

            R = Paint::R

            # WHERE THE PICTURE'S PIXELS ARE KEPT: the pixel rows painted, +first_row+ to before
            # +past_row+, which are the rows shown. A game that gives rows up (`shown_rows:`) never
            # sees them, as the screen is switched off there, so painting is held to the rows shown
            # as an area holds it (rt_paint_anywhere), and only the rows of tiles they are in are
            # kept, in the copy and in video RAM: a column of tiles is the shown ones alone, and a
            # picture that changes all its shown rows is still one run of bytes to copy.
            Layout = Data.define(:first_row, :past_row) do
              def first_tile_row = first_row / 8
              def tile_rows = ((past_row + 7) / 8) - first_tile_row
              # A column of tiles, top to bottom: its bytes one after another.
              def column_bytes = tile_rows * TILE_BYTES
              def copy_bytes = COLUMNS * column_bytes

              # The copy's byte of the top left pixel of column of tiles +column+, less the rows of
              # tiles not kept above it, in 16 bits: the pixel (x, y) is this for x ÷ 8, and y × 8
              # and x mod 8 more (rt_paint_doubled_at).
              def column_start(column) = ((column * column_bytes) - (first_tile_row * TILE_BYTES)) & 0xFFFF
            end

            # The Layout of a screen whose console lines shown are +band+ (Letterbox.band_of), nil
            # for all: each pixel row is PIXEL_SIZE of the console's lines, and the screen's row y is
            # the console's line y + 1.
            def self.layout(band)
              return Layout.new(first_row: 0, past_row: HEIGHT) unless band

              first, last = band
              Layout.new(first_row: (first - 1) / PIXEL_SIZE, past_row: ((last - 1) / PIXEL_SIZE) + 1)
            end

            # The direct page the routine that marks rows changed reads (rt_paint_doubled_mark): the
            # pixel rows from +top+ to before +bottom+, in the columns of tiles that the pixels from
            # +left+ to before +right+ are in. Paint's scratch, named for what it holds here.
            Mark = Data.define(:top, :bottom, :left, :right)

            # A column's numbers (rt_paint_column), 32 bits each on a part of the direct page of their
            # own, which nothing the lowering works a number out with touches: so it writes each
            # straight there as it has it, with no working number to move it through. The top is
            # the last worked out, and is left where it was worked out, in R0.
            # Must not read the top after rt_paint_column_shown: the walk's rt_mul32 and rt_div32
            # write R0.
            COLUMN_NUMBERS = "rt paint doubled column numbers"
            ColumnNumbers = Data.define(:height, :slice, :x, :top, :width, :record)

            # The direct page of rt_paint_doubled_at: the pixel +x+ and +y+, and its sum so far.
            At = Data.define(:x, :y, :sum)

            # The direct page of a fill (rt_paint_fill): the rectangle, the colour's place in both
            # bytes of +colour+, +source+ where that place is in "rt paint doubled places" for the
            # copying engine to send, +x+ the next pixel across to fill, +bytes+ a column of tiles'
            # bytes the rectangle covers, +rows+ its rows, +rows_left+ and +pixels+ for a column of
            # tiles it covers only part of.
            Fill = Data.define(:left, :right, :top, :bottom, :colour, :source, :x, :bytes, :rows, :rows_left, :pixels)

            # The direct page of a column (rt_paint_column): the rows of the picture's column shown,
            # +first+ to before +past+ (32 bits each), and how many, +rows+; the pixels across,
            # +across_first+ to before +across_past+ (32 bits each), and how many, +across+; where the
            # column's places are (+source+, a long address, and in its top byte whether it has
            # see-through pixels); the code for its height (+scaler+, a long address); the step down
            # the picture in 65536ths (+step+, 32 bits); the byte of the copy the first row is
            # written at (+dest+); a table being read (+table+, a long address); whether it is walked
            # a row at a time (+walk+, nought for not) and for one walked, where the walk starts
            # (+source_start+ and +fraction_start+) and stands (+fraction+, +rows_left+).
            Column = Data.define(:first, :past, :rows, :across_first, :across_past, :across, :source, :scaler, :step,
                                 :dest, :table, :walk, :source_start, :fraction_start, :fraction, :rows_left)

            module_function

            def mark_scratch(s) = Mark.new(top: s.mark_row, bottom: s.mark_count, left: s.y, right: s.shift)

            def at_scratch(s) = At.new(x: s.column, y: s.last, sum: s.tile)

            def fill_scratch(s)
              Fill.new(left: s.left, right: s.right, top: s.top, bottom: s.bottom, colour: s.mask, source: s.temp,
                       x: s.across, bytes: s.chunk, rows: s.height, rows_left: s.count, pixels: s.first_x)
            end

            def column_scratch(s)
              Column.new(first: s.temp, past: s.planes, rows: s.height, across_first: s.left_planes,
                         across_past: s.right_planes, across: s.across, source: s.pointer, scaler: s.planes + 4,
                         step: s.left_planes + 4, dest: s.chunk, table: s.right_planes + 4, walk: s.first_x,
                         source_start: s.row, fraction_start: s.not_mask, fraction: s.mask, rows_left: s.count)
            end

            # +band+ as #emit has it; +behind+ for two copies, the next painted while the last is
            # sent (PaintDoubledSend.behind_for?).
            def reserve(memory, band: nil, behind: false)
              bytes = layout(band).copy_bytes * (behind ? 2 : 1)
              copy = memory.reserve_last_bank(COPY, bytes)
              # The copy's bytes are counted in 16 bits from its start (rt_paint_doubled_at).
              raise LoweringError, "the copy of the screen must not cross a bank of work RAM" if (copy & 0xFFFF) + bytes > 0x10000

              memory.reserve(Paint::AREA, Paint::AREA_WORDS * 2)
              memory.reserve(DIRTY_TOP, COLUMNS * 2)
              memory.reserve(DIRTY_BOTTOM, COLUMNS * 2)
              memory.reserve(MARK_LAST, 2)
              memory.reserve(MARK_FILLED, 2)
              memory.reserve_scratch(COLUMN_NUMBERS, (ColumnNumbers.members.size - 1) * 4)
              PaintDoubledSend.reserve(memory, behind: behind)
            end

            # Where rt_paint_column's numbers are on the direct page, four bytes each.
            def column_numbers(memory)
              at = memory[COLUMN_NUMBERS]
              kept = (ColumnNumbers.members - [:top]).each_with_index.to_h { |name, i| [name, at + (i * 4)] }
              ColumnNumbers.new(top: R.call(0), **kept)
            end

            def kept?(memory) = memory.reserved?(COPY)

            # +s+ is Paint's scratch (Paint.scratch): the same direct page, named for each routine
            # here (#mark_scratch and the rest). +band+ is the console's first and last line shown
            # (Letterbox.band_of), or nil for all. +columns+ for a game that draws columns of
            # pictures (Lowering::Paint#paints_columns?).
            def emit(asm, memory, s, band: nil, columns: false)
              shown = layout(band)
              emit_start(asm, memory, shown)
              Paint.emit_area(asm, memory, s, width: WIDTH, top: shown.first_row, height: shown.past_row)
              emit_helpers(asm, memory, s)
              emit_clear(asm, memory, s, shown)
              emit_fill(asm, memory, s)
              emit_column(asm, memory, s, shown) if columns
              emit_blit(asm, memory, s, shown)
              emit_patches(asm, memory, s, shown)
              asm.label("rt_paint_prepare")
              asm.rtl
              PaintDoubledSend.emit_upload(asm, memory, shown)
              PaintDoubledSend.emit_stale_row_copies(asm, memory, mark_scratch(s), shown, memory[MARK_LAST])
              emit_tables(asm, shown)
            end

            # --- power-on ---

            def emit_start(asm, memory, shown)
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
              # The map: its low bytes alone, so the address moves on after each low byte. Row by
              # row of the cells shown; along a row the tiles go up by a column of tiles. The cells
              # of rows given up stay tile 0, as Boot leaves them: the screen is off there.
              asm.stz(asm.abs(h::VMAIN))
              asm.rep(0x20)
              asm.ldx(shown.first_tile_row)
              asm.label("rt_paint_doubled_start_row")
              asm.txa # the row's cells are at row × 128
              7.times { asm.asl }
              asm.sta(asm.abs(h::VMADDL))
              asm.txa # the row's first tile is its number among the rows kept
              asm.sec
              asm.sbc(shown.first_tile_row)
              asm.ldy(COLUMNS)
              asm.label("rt_paint_doubled_start_cell")
              asm.sep(0x20)
              asm.sta(asm.abs(h::VMDATAL))
              asm.rep(0x20)
              asm.clc
              asm.adc(shown.tile_rows)
              asm.dey
              asm.bne("rt_paint_doubled_start_cell")
              asm.inx
              asm.cpx(shown.first_tile_row + shown.tile_rows)
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
              asm.ldx(0)
              asm.label("rt_paint_doubled_start_none_changed")
              asm.lda(HEIGHT)
              asm.sta(asm.abs_x(memory[DIRTY_TOP]))
              asm.stz(asm.abs_x(memory[DIRTY_BOTTOM]))
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("rt_paint_doubled_start_none_changed")
              PaintDoubledSend.emit_start(asm, memory)
              Letterbox.emit_start(asm, memory) if Letterbox.kept?(memory)
              asm.rtl
            end

            # --- helpers ---

            # rt_paint_take_area: the area into the direct page (s.area).
            # rt_paint_doubled_at: A = the byte for the pixel (At) in the copy painted. Uses X.
            # rt_paint_doubled_mark: the rows and columns of tiles of Mark marked changed (its
            #   bottom past its top and its right past its left), and with two copies, the one
            #   painted brought up to the other there first (PaintDoubledSend). Uses X.
            #   rt_paint_doubled_mark_fill: the same for a fill, which covers what it paints.
            # rt_paint_doubled_fill_bytes: s.chunk bytes of the copy painted from its byte A filled
            #   with the byte at s.temp in "rt paint doubled places", by the copying engine sending it
            #   over and over to work RAM's port.
            def emit_helpers(asm, memory, s)
              area = memory[Paint::AREA]
              asm.label("rt_paint_take_area")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.direct(s.area + (i * 2)))
              end
              asm.rts

              at = at_scratch(s)
              asm.label("rt_paint_doubled_at")
              asm.lda(asm.direct(at.x))
              emit_column_of_tiles(asm)
              asm.lda(asm.direct(at.y))
              3.times { asm.asl }
              asm.clc
              asm.adc(PaintDoubledSend.painted_start(asm, memory))
              asm.sta(asm.direct(at.sum))
              asm.lda(asm.direct(at.x))
              asm.and_a(0x0007)
              asm.clc
              asm.adc(asm.direct(at.sum))
              asm.rts

              mark = mark_scratch(s)
              asm.label("rt_paint_doubled_mark_fill")
              asm.lda(1)
              asm.bra("rt_paint_doubled_mark_filled")
              asm.label("rt_paint_doubled_mark")
              asm.lda(0)
              asm.label("rt_paint_doubled_mark_filled")
              asm.sta(asm.abs(memory[MARK_FILLED]))
              asm.lda(asm.direct(mark.right))
              asm.dec
              emit_column_of_tiles(asm)
              asm.stx(asm.abs(memory[MARK_LAST]))
              asm.lda(asm.direct(mark.left))
              emit_column_of_tiles(asm)
              asm.label("rt_paint_doubled_mark_column")
              PaintDoubledSend.emit_stale_rows_copied_for_mark(asm, memory, mark, memory[MARK_FILLED])
              asm.lda(asm.direct(mark.top))
              asm.cmp(asm.abs_x(memory[DIRTY_TOP]))
              asm.bcs("rt_paint_doubled_mark_top_kept")
              asm.sta(asm.abs_x(memory[DIRTY_TOP]))
              asm.label("rt_paint_doubled_mark_top_kept")
              asm.lda(asm.direct(mark.bottom))
              asm.cmp(asm.abs_x(memory[DIRTY_BOTTOM]))
              asm.bcc("rt_paint_doubled_mark_bottom_kept")
              asm.sta(asm.abs_x(memory[DIRTY_BOTTOM]))
              asm.label("rt_paint_doubled_mark_bottom_kept")
              asm.cpx(asm.abs(memory[MARK_LAST]))
              asm.beq("rt_paint_doubled_mark_done")
              asm.inx
              asm.inx
              asm.brl("rt_paint_doubled_mark_column")
              asm.label("rt_paint_doubled_mark_done")
              asm.rts

              emit_fill_bytes(asm, memory, s)
            end

            # X = the column of tiles the pixel across in A is in, two bytes a column, for the
            # tables kept a word for each (DIRTY_TOP, "rt paint doubled column starts").
            def emit_column_of_tiles(asm)
              asm.lsr
              asm.lsr
              asm.and_a(0x003E)
              asm.tax
            end

            # X on from a pixel's byte to the next pixel across's: the next byte, or from a tile's
            # row's last byte the same row of the next column of tiles (+shown+'s).
            def emit_next_byte(asm, prefix, shown)
              asm.txa
              asm.and_a(0x0007)
              asm.cmp(0x0007)
              asm.beq("#{prefix}_next_tile")
              asm.inx
              asm.bra("#{prefix}_moved")
              asm.label("#{prefix}_next_tile")
              asm.txa
              asm.clc
              asm.adc(shown.column_bytes - 7)
              asm.tax
              asm.label("#{prefix}_moved")
            end

            # rt_paint_doubled_fill_ready sets channel 0 to send the byte at s.temp, and
            # rt_paint_doubled_fill_more is rt_paint_doubled_fill_bytes with the channel set
            # already, as it is for every column of tiles of one fill.
            def emit_fill_bytes(asm, memory, s)
              h = Console::SNESHardware
              offset = memory[COPY] - Picture::WORK_RAM
              asm.label("rt_paint_doubled_fill_bytes")
              asm.tax
              asm.jsr(asm.abs("rt_paint_doubled_fill_ready"))
              asm.txa
              asm.label("rt_paint_doubled_fill_more")
              PaintDoubledSend.emit_paint_offset_added(asm, memory)
              asm.clc
              asm.adc(offset & 0xFFFF)
              asm.sta(asm.abs(h::WMADDL))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(offset >> 16)
              asm.sta(asm.abs(h::WMADDL + 2))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.rts

              asm.label("rt_paint_doubled_fill_ready")
              asm.lda(asm.direct(s.temp))
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(asm.bank_of("rt paint doubled places"))
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_ONE_PORT | h::DMA_FIXED_SOURCE)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::WMDATA & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.rep(0x20)
              asm.rts
            end

            # s.temp = where the place at +place+ (a working number) is in "rt paint doubled
            # places", for rt_paint_doubled_fill_bytes.
            def emit_fill_source(asm, s, place)
              asm.lda(asm.direct(place))
              asm.and_a(0x00FF)
              asm.clc
              asm.adc(asm.imm("rt paint doubled places"))
              asm.sta(asm.direct(s.temp))
            end

            # +out+ = the place at +at+ (32 bits) with NEAR added, as 16 bits; on to +outside+ when
            # that is below nought or not before NEAR + +edge+.
            def emit_near_place(asm, at, edge, out, outside)
              asm.clc
              asm.lda(asm.direct(at))
              asm.adc(NEAR)
              asm.sta(asm.direct(out))
              asm.lda(asm.direct(at + 2))
              asm.adc(0)
              asm.branch_long(:bne, outside)
              asm.lda(asm.direct(out))
              asm.cmp(NEAR + edge)
              asm.branch_long(:bcs, outside)
            end

            # --- clear and fill ---

            # rt_paint_clear(place): the area, or with the whole screen to paint in, the whole copy
            # filled by the copying engine with the byte at "rt paint doubled places" + place.
            def emit_clear(asm, memory, s, shown)
              asm.label("rt_paint_clear")
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[s.area_left, 0], [s.area_top, shown.first_row], [s.area_right, WIDTH]].each do |edge, whole|
                asm.lda(asm.direct(edge))
                asm.cmp(whole)
                asm.bne("rt_paint_clear_area")
              end
              asm.lda(asm.direct(s.area_bottom))
              asm.cmp(shown.past_row)
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
              asm.lda(shown.copy_bytes)
              asm.sta(asm.direct(s.chunk))
              emit_fill_source(asm, s, R.call(0))
              asm.lda(0)
              asm.jsr(asm.abs("rt_paint_doubled_fill_bytes"))
              asm.ldx(0)
              asm.label("rt_paint_clear_whole_changed")
              asm.lda(shown.first_row)
              asm.sta(asm.abs_x(memory[DIRTY_TOP]))
              asm.lda(shown.past_row)
              asm.sta(asm.abs_x(memory[DIRTY_BOTTOM]))
              if PaintDoubledSend.behind?(memory) # every row of the copy painted is new
                asm.lda(HEIGHT)
                asm.sta(asm.abs_x(memory[PaintDoubledSend::STALE_TOP]))
                asm.stz(asm.abs_x(memory[PaintDoubledSend::STALE_BOTTOM]))
              end
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("rt_paint_clear_whole_changed")
              asm.rtl
            end

            # rt_paint_fill(x, y, w, h, place): the rectangle, inside the area, a column of tiles at
            # a time (Fill): one it covers from side to side is the copying engine filling the
            # rows' bytes, which are one after another there; one it covers part of is written a
            # byte at a time, row by row.
            def emit_fill(asm, memory, s)
              f = fill_scratch(s)
              mark = mark_scratch(s)
              at = at_scratch(s)
              copy = memory[COPY]
              asm.label("rt_paint_fill")
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[R.call(0), R.call(2), R.call(5)], [R.call(1), R.call(3), R.call(6)]].each do |from, size, out|
                asm.clc
                asm.lda(asm.direct(from))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(from + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              Paint.emit_clamp(asm, "doubled fill", R.call(0), s.area_left, s.area_right, f.left)
              Paint.emit_clamp(asm, "doubled fill", R.call(5), s.area_left, s.area_right, f.right)
              Paint.emit_clamp(asm, "doubled fill", R.call(1), s.area_top, s.area_bottom, f.top)
              Paint.emit_clamp(asm, "doubled fill", R.call(6), s.area_top, s.area_bottom, f.bottom)
              asm.lda(asm.direct(f.left))
              asm.cmp(asm.direct(f.right))
              asm.bcs("rt_paint_fill_none")
              asm.lda(asm.direct(f.top))
              asm.cmp(asm.direct(f.bottom))
              asm.bcc("rt_paint_fill_some")
              asm.label("rt_paint_fill_none")
              asm.rtl
              asm.label("rt_paint_fill_some")
              [[f.top, mark.top], [f.bottom, mark.bottom], [f.left, mark.left], [f.right, mark.right]].each do |from, out|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(out))
              end
              asm.jsr(asm.abs("rt_paint_doubled_mark_fill"))
              # The colour's place in both bytes, and where it is for the copying engine.
              asm.lda(asm.direct(R.call(4)))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(f.colour))
              asm.xba
              asm.ora(asm.direct(f.colour))
              asm.sta(asm.direct(f.colour))
              emit_fill_source(asm, s, R.call(4))
              asm.jsr(asm.abs("rt_paint_doubled_fill_ready"))
              asm.lda(asm.direct(f.bottom))
              asm.sec
              asm.sbc(asm.direct(f.top))
              asm.sta(asm.direct(f.rows))
              3.times { asm.asl }
              asm.sta(asm.direct(f.bytes))
              asm.lda(asm.direct(f.left))
              asm.sta(asm.direct(f.x))

              asm.label("rt_paint_fill_across")
              asm.lda(asm.direct(f.x))
              asm.cmp(asm.direct(f.right))
              asm.bcc("rt_paint_fill_more")
              asm.rtl
              asm.label("rt_paint_fill_more")
              asm.and_a(0x0007)
              asm.bne("rt_paint_fill_part")
              asm.lda(asm.direct(f.x))
              asm.clc
              asm.adc(8)
              asm.cmp(asm.direct(f.right))
              asm.beq("rt_paint_fill_whole")
              asm.bcs("rt_paint_fill_part")
              asm.label("rt_paint_fill_whole")
              asm.lda(asm.direct(f.x))
              emit_column_of_tiles(asm)
              asm.lda(asm.direct(f.top))
              3.times { asm.asl }
              asm.clc
              asm.adc(asm.long_x("rt paint doubled column starts"))
              asm.jsr(asm.abs("rt_paint_doubled_fill_more"))
              asm.lda(asm.direct(f.x))
              asm.clc
              asm.adc(8)
              asm.sta(asm.direct(f.x))
              asm.bra("rt_paint_fill_across")

              # The pixels to the end of the tile, or to the rectangle's right if that is sooner.
              asm.label("rt_paint_fill_part")
              asm.lda(asm.direct(f.x))
              asm.ora(0x0007)
              asm.inc
              asm.cmp(asm.direct(f.right))
              asm.bcc("rt_paint_fill_part_end")
              asm.lda(asm.direct(f.right))
              asm.label("rt_paint_fill_part_end")
              asm.sec
              asm.sbc(asm.direct(f.x))
              asm.sta(asm.direct(f.pixels))
              asm.lda(asm.direct(f.x))
              asm.sta(asm.direct(at.x))
              asm.lda(asm.direct(f.top))
              asm.sta(asm.direct(at.y))
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.tax
              asm.lda(asm.direct(f.rows))
              asm.sta(asm.direct(f.rows_left))
              asm.sep(0x20)
              asm.label("rt_paint_fill_part_row")
              asm.lda(asm.direct(f.colour))
              asm.ldy(asm.direct(f.pixels))
              asm.phx
              asm.label("rt_paint_fill_part_byte")
              asm.sta(asm.long_x(copy))
              asm.inx
              asm.dey
              asm.bne("rt_paint_fill_part_byte")
              asm.plx
              asm.rep(0x20)
              asm.txa
              asm.clc
              asm.adc(ROW_STEP)
              asm.tax
              asm.sep(0x20)
              asm.dec(asm.direct(f.rows_left)) # a byte: the rows are fewer than 256
              asm.bne("rt_paint_fill_part_row")
              asm.rep(0x20)
              asm.lda(asm.direct(f.x))
              asm.clc
              asm.adc(asm.direct(f.pixels))
              asm.sta(asm.direct(f.x))
              asm.brl("rt_paint_fill_across")
            end

            # --- a picture's column, stretched ---

            # rt_paint_column: Reference#exec_draw_column_at, the column's numbers handed over in
            # ColumnNumbers, where the lowering writes them as it works them out
            # (Lowering::Paint#emit_doubled_column): its height (above nought), slice, x, top and
            # width, 32 bits each, and the picture's record (RECORD_STARTS and the rest); the step
            # down the picture is worked out here. The rows and pixels across shown are the ones
            # inside the area, worked out in 32 bits, so a column far off the screen whose width or
            # height still reaches it is drawn.
            #
            # CODE MADE FOR EACH HEIGHT. A column shown whole and with no see-through pixel, the walls
            # of a view at any distance, is drawn by the code made for its height when the game was
            # built (#scaler_sections): a byte read from the picture's column and written to the
            # copy for each row, at places worked out then, and the read left out where a row shows
            # the same pixel of the picture as the row above. It runs with the column in Y and the
            # data bank, and the copy's byte for its top in X. That is how the console's own 3D
            # games drew walls fast enough: nothing is worked out a row at a time.
            #
            # Any other column is walked a row at a time: the place down the picture in 65536ths
            # added up a step a row, its whole part the byte read, and a see-through place left
            # alone. A column cut at the top starts the walk where the first row shown is.
            def emit_column(asm, memory, s, shown)
              c = column_scratch(s)
              mark = mark_scratch(s)
              at = at_scratch(s)
              copy = memory[COPY]
              n = column_numbers(memory)
              height, slice, x, top, width, record = n.height, n.slice, n.x, n.top, n.width, n.record
              asm.label("rt_paint_column")
              emit_column_whole_in_one_tile(asm, memory, c, mark, height, x, top, width)
              asm.jsr(asm.abs("rt_paint_take_area"))
              emit_column_shown_small(asm, s, c, height, x, top, width)
              # The rows shown: from the area's top or the column's, whichever is lower, to its
              # bottom or the column's.
              emit_from_edge(asm, s.area_top, top, c.first, "rt_paint_column_first")
              asm.lda(asm.direct(c.first + 2))
              asm.bpl("rt_paint_column_first_kept")
              asm.stz(asm.direct(c.first))
              asm.stz(asm.direct(c.first + 2))
              asm.label("rt_paint_column_first_kept")
              emit_from_edge(asm, s.area_bottom, top, c.past, "rt_paint_column_past")
              emit_branch_unless_below(asm, height, c.past, "rt_paint_column_past_kept")
              asm.lda(asm.direct(height))
              asm.sta(asm.direct(c.past))
              asm.lda(asm.direct(height + 2))
              asm.sta(asm.direct(c.past + 2))
              asm.label("rt_paint_column_past_kept")
              emit_branch_unless_below(asm, c.first, c.past, "rt_paint_column_none")
              asm.lda(asm.direct(c.past))
              asm.sec
              asm.sbc(asm.direct(c.first))
              asm.sta(asm.direct(c.rows))
              # The pixels across, the same way.
              emit_from_edge(asm, s.area_left, x, c.across_first, "rt_paint_column_across_first")
              asm.lda(asm.direct(c.across_first + 2))
              asm.bpl("rt_paint_column_across_first_kept")
              asm.stz(asm.direct(c.across_first))
              asm.stz(asm.direct(c.across_first + 2))
              asm.label("rt_paint_column_across_first_kept")
              emit_from_edge(asm, s.area_right, x, c.across_past, "rt_paint_column_across_past")
              emit_branch_unless_below(asm, width, c.across_past, "rt_paint_column_across_past_kept")
              asm.lda(asm.direct(width))
              asm.sta(asm.direct(c.across_past))
              asm.lda(asm.direct(width + 2))
              asm.sta(asm.direct(c.across_past + 2))
              asm.label("rt_paint_column_across_past_kept")
              emit_branch_unless_below(asm, c.across_first, c.across_past, "rt_paint_column_none")
              asm.lda(asm.direct(c.across_past))
              asm.sec
              asm.sbc(asm.direct(c.across_first))
              asm.sta(asm.direct(c.across))
              # Where on the screen it starts, the rows and columns of tiles marked changed, and
              # the copy's byte there.
              asm.label("rt_paint_column_shown")
              asm.lda(asm.direct(top))
              asm.clc
              asm.adc(asm.direct(c.first))
              asm.sta(asm.direct(mark.top))
              asm.sta(asm.direct(at.y))
              asm.clc
              asm.adc(asm.direct(c.rows))
              asm.sta(asm.direct(mark.bottom))
              asm.lda(asm.direct(x))
              asm.clc
              asm.adc(asm.direct(c.across_first))
              asm.sta(asm.direct(mark.left))
              asm.sta(asm.direct(at.x))
              asm.clc
              asm.adc(asm.direct(c.across))
              asm.sta(asm.direct(mark.right))
              asm.jsr(asm.abs("rt_paint_doubled_mark"))
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.sta(asm.direct(c.dest))
              # Walked a row at a time unless it is shown whole, from its first row to its last.
              asm.stz(asm.direct(c.walk))
              asm.lda(asm.direct(c.first))
              asm.ora(asm.direct(c.first + 2))
              asm.ora(asm.direct(height + 2))
              asm.bne("rt_paint_column_cut")
              asm.lda(asm.direct(c.rows))
              asm.cmp(asm.direct(height))
              asm.beq("rt_paint_column_picture")
              asm.label("rt_paint_column_cut")
              asm.inc(asm.direct(c.walk))
              # The picture's column, held to its first and last.
              asm.label("rt_paint_column_picture")
              asm.ldy(RECORD_WIDTH)
              asm.lda(asm.direct(slice + 2))
              asm.bmi("rt_paint_column_slice_first")
              asm.bne("rt_paint_column_slice_last")
              asm.lda(asm.direct(slice))
              asm.cmp(asm.ind_long_y(record))
              asm.bcc("rt_paint_column_slice_kept")
              asm.label("rt_paint_column_slice_last")
              asm.lda(asm.ind_long_y(record))
              asm.dec
              asm.bra("rt_paint_column_slice_kept")
              asm.label("rt_paint_column_slice_first")
              asm.lda(0)
              asm.label("rt_paint_column_slice_kept")
              asm.asl
              asm.asl
              asm.clc
              asm.adc(RECORD_STARTS)
              asm.tay
              asm.lda(asm.ind_long_y(record))
              asm.sta(asm.direct(c.source))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(record))
              asm.sta(asm.direct(c.source + 2))
              # Shown whole, so of a height there is code for, with no see-through pixel: that code.
              # One shown whole with see-through pixels is walked from its first row: the wall's
              # own way here (rt_paint_column_whole_in_one_tile) leaves its rows unwritten.
              asm.and_a(0xFF00)
              asm.bne("rt_paint_column_see_through")
              asm.lda(asm.direct(c.walk))
              asm.bne("rt_paint_column_walked")
              asm.lda(asm.direct(height))
              asm.asl
              asm.asl
              asm.clc
              asm.adc(RECORD_SCALERS)
              asm.tay
              asm.lda(asm.ind_long_y(record))
              asm.sta(asm.direct(c.scaler))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(record))
              asm.sta(asm.direct(c.scaler + 2))
              asm.phb
              asm.ldx(asm.direct(c.dest))
              asm.ldy(asm.direct(c.source))
              asm.sep(0x20)
              asm.lda(asm.direct(c.source + 2))
              asm.pha
              asm.plb
              asm.label("rt_paint_column_scaled")
              asm.jsl(asm.long("rt_paint_column_scale"))
              asm.dec(asm.direct(c.across)) # a byte: no more than the screen's width
              asm.beq("rt_paint_column_scaled_done")
              asm.rep(0x20)
              emit_next_byte(asm, "rt_paint_column_scaled", shown)
              asm.sep(0x20)
              asm.bra("rt_paint_column_scaled")
              asm.label("rt_paint_column_scaled_done")
              asm.rep(0x20)
              asm.plb
              asm.label("rt_paint_column_none")
              asm.rtl

              # The code for a height is reached through its long address on the direct page; it
              # returns with RTL to rt_paint_column's JSL.
              asm.label("rt_paint_column_scale")
              asm.jml(asm.ind_long_abs(c.scaler))

              emit_column_walk(asm, s, c, copy, height, record, shown)
            end

            # rt_paint_column's column walked a row at a time (Column), each pixel across in turn.
            def emit_column_walk(asm, s, c, copy, height, record, shown)
              asm.widths(a16: true, xy16: true)
              asm.label("rt_paint_column_see_through")
              asm.lda(asm.direct(c.walk))
              asm.bne("rt_paint_column_walked")
              asm.stz(asm.direct(c.first))
              asm.stz(asm.direct(c.first + 2))
              asm.lda(asm.direct(height))
              asm.sta(asm.direct(c.rows))
              asm.label("rt_paint_column_walked")
              # The step: from the record's table, or for a tall column, the picture's height in
              # 65536ths divided by the column's (rt_div32, R0 ÷ R1).
              asm.lda(asm.direct(height + 2))
              asm.bne("rt_paint_column_step_given")
              asm.lda(asm.direct(height))
              asm.cmp(STEP_TABLE_HEIGHTS)
              asm.bcs("rt_paint_column_step_given")
              emit_record_table(asm, record, RECORD_STEPS, c.table)
              asm.lda(asm.direct(height))
              asm.asl
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(c.table))
              asm.sta(asm.direct(c.step))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(c.table))
              asm.sta(asm.direct(c.step + 2))
              asm.bra("rt_paint_column_step_known")
              asm.label("rt_paint_column_step_given")
              asm.stz(asm.direct(R.call(0)))
              asm.ldy(RECORD_HEIGHT)
              asm.lda(asm.ind_long_y(record))
              asm.sta(asm.direct(R.call(0) + 2))
              asm.lda(asm.direct(height))
              asm.sta(asm.direct(R.call(1)))
              asm.lda(asm.direct(height + 2))
              asm.sta(asm.direct(R.call(1) + 2))
              asm.jsl(asm.long("rt_div32"))
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(c.step))
              asm.lda(asm.direct(R.call(0) + 2))
              asm.sta(asm.direct(c.step + 2))
              asm.label("rt_paint_column_step_known")
              # Where the walk starts: the first row shown × the step, its whole part a byte down
              # the column (rt_mul32, R0 × R1).
              asm.stz(asm.direct(c.fraction_start))
              asm.stz(asm.direct(c.source_start))
              asm.lda(asm.direct(c.first))
              asm.ora(asm.direct(c.first + 2))
              asm.beq("rt_paint_column_walk_from_top")
              [[c.first, R.call(0)], [c.step, R.call(1)]].each do |from, out|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(from + 2))
                asm.sta(asm.direct(out + 2))
              end
              asm.jsl(asm.long("rt_mul32"))
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(c.fraction_start))
              asm.lda(asm.direct(R.call(0) + 2))
              asm.sta(asm.direct(c.source_start))
              asm.label("rt_paint_column_walk_from_top")
              asm.lda(asm.direct(c.source))
              asm.clc
              asm.adc(asm.direct(c.source_start))
              asm.sta(asm.direct(c.source_start))
              asm.phb
              asm.sep(0x20)
              asm.lda(asm.direct(c.source + 2))
              asm.pha
              asm.plb
              asm.rep(0x20)
              asm.label("rt_paint_column_walk_across")
              asm.ldx(asm.direct(c.dest))
              asm.ldy(asm.direct(c.source_start))
              asm.lda(asm.direct(c.fraction_start))
              asm.sta(asm.direct(c.fraction))
              asm.lda(asm.direct(c.rows))
              asm.sta(asm.direct(c.rows_left))
              asm.label("rt_paint_column_walk_row")
              asm.sep(0x20)
              asm.lda(asm.abs_y(0))
              asm.cmp(Lowering::Paint::SEE_THROUGH)
              asm.beq("rt_paint_column_walk_see_through")
              asm.sta(asm.long_x(copy))
              asm.label("rt_paint_column_walk_see_through")
              asm.rep(0x20)
              asm.lda(asm.direct(c.fraction))
              asm.clc
              asm.adc(asm.direct(c.step))
              asm.sta(asm.direct(c.fraction))
              asm.tya
              asm.adc(asm.direct(c.step + 2))
              asm.tay
              asm.txa
              asm.clc
              asm.adc(ROW_STEP)
              asm.tax
              asm.dec(asm.direct(c.rows_left))
              asm.bne("rt_paint_column_walk_row")
              asm.dec(asm.direct(c.across))
              asm.beq("rt_paint_column_walk_done")
              asm.ldx(asm.direct(c.dest))
              emit_next_byte(asm, "rt_paint_column_walk", shown)
              asm.stx(asm.direct(c.dest))
              asm.bra("rt_paint_column_walk_across")
              asm.label("rt_paint_column_walk_done")
              asm.plb
              asm.rtl
            end

            # THE WALL OF A VIEW: a column wholly inside the area, in one column of tiles, with every
            # number in 16 bits and none below nought, where the copy painted is not behind. Its
            # rows are all of them and its pixels across all of its width, its one column of tiles
            # is marked here, and it goes straight on to its picture (rt_paint_column_picture). Any
            # other goes on to the sums after this.
            def emit_column_whole_in_one_tile(asm, memory, c, mark, height, x, top, width)
              area = memory[Paint::AREA]
              # Each look below goes on to the sums by a short branch back to here, which is cheaper
              # than a long one forward as long as the look passes.
              asm.bra("rt_paint_column_whole_looks")
              asm.label("rt_paint_column_not_whole_far")
              asm.brl("rt_paint_column_not_whole")
              asm.label("rt_paint_column_whole_looks")
              asm.lda(asm.direct(height + 2))
              asm.ora(asm.direct(width + 2))
              asm.ora(asm.direct(top + 2))
              asm.ora(asm.direct(x + 2))
              asm.bne("rt_paint_column_not_whole_far")
              [[top, height, area + 2, area + 6, mark.bottom], [x, width, area, area + 4, mark.right]].each do |at, size, low, high, out|
                asm.lda(asm.direct(at))
                asm.cmp(asm.abs(low))
                asm.bcc("rt_paint_column_not_whole_far")
                asm.clc
                asm.adc(asm.direct(size))
                asm.bcs("rt_paint_column_not_whole_far")
                asm.cmp(asm.abs(high))
                asm.beq("rt_paint_column_whole_#{out}")
                asm.bcs("rt_paint_column_not_whole_far")
                asm.label("rt_paint_column_whole_#{out}")
                asm.sta(asm.direct(out))
              end
              # Its first and last pixel across in one column of tiles: all but their low three bits alike.
              asm.dec
              asm.eor(asm.direct(x))
              asm.and_a(0xFFF8)
              asm.bne("rt_paint_column_not_whole_far")
              asm.lda(asm.direct(x))
              emit_column_of_tiles(asm)
              if PaintDoubledSend.behind?(memory)
                asm.lda(asm.abs_x(memory[PaintDoubledSend::STALE_TOP]))
                asm.cmp(asm.abs_x(memory[PaintDoubledSend::STALE_BOTTOM]))
                asm.bcc("rt_paint_column_not_whole_far")
              end
              asm.lda(asm.direct(width))
              asm.sta(asm.direct(c.across))
              asm.lda(asm.direct(top))
              asm.cmp(asm.abs_x(memory[DIRTY_TOP]))
              asm.bcs("rt_paint_column_whole_top_kept")
              asm.sta(asm.abs_x(memory[DIRTY_TOP]))
              asm.label("rt_paint_column_whole_top_kept")
              asm.lda(asm.direct(mark.bottom))
              asm.cmp(asm.abs_x(memory[DIRTY_BOTTOM]))
              asm.bcc("rt_paint_column_whole_bottom_kept")
              asm.sta(asm.abs_x(memory[DIRTY_BOTTOM]))
              asm.label("rt_paint_column_whole_bottom_kept")
              # The copy's byte for its top: its column of tiles' start, the row × 8 and the pixel
              # across in the tile.
              asm.lda(asm.direct(top))
              3.times { asm.asl }
              asm.clc
              asm.adc(PaintDoubledSend.painted_start(asm, memory))
              asm.sta(asm.direct(c.dest))
              asm.lda(asm.direct(x))
              asm.and_a(0x0007)
              asm.clc
              asm.adc(asm.direct(c.dest))
              asm.sta(asm.direct(c.dest))
              asm.stz(asm.direct(c.walk))
              asm.brl("rt_paint_column_picture")
              asm.label("rt_paint_column_not_whole")
            end

            # THE USUAL COLUMN, its numbers all well inside 16 bits: a height and a width below
            # SMALL, and a place across and down no further than SMALL either side of nought. Its
            # rows and pixels across shown are worked out in 16 bits, which nothing there can
            # overflow, and it goes on to rt_paint_column_shown; any other goes on to the 32-bit
            # sums after this.
            SMALL = 0x4000

            def emit_column_shown_small(asm, s, c, height, x, top, width)
              asm.lda(asm.direct(height + 2))
              asm.ora(asm.direct(width + 2))
              asm.branch_long(:bne, "rt_paint_column_large")
              asm.lda(asm.direct(height))
              asm.ora(asm.direct(width))
              asm.and_a(0x10000 - SMALL)
              asm.branch_long(:bne, "rt_paint_column_large")
              [[top, "top"], [x, "x"]].each do |at, what|
                asm.lda(asm.direct(at + 2))
                asm.beq("rt_paint_column_small_#{what}_up")
                asm.cmp(0xFFFF)
                asm.branch_long(:bne, "rt_paint_column_large")
                asm.lda(asm.direct(at))
                asm.cmp(0x10000 - SMALL)
                asm.branch_long(:bcc, "rt_paint_column_large")
                asm.bra("rt_paint_column_small_#{what}_kept")
                asm.label("rt_paint_column_small_#{what}_up")
                asm.lda(asm.direct(at))
                asm.cmp(SMALL)
                asm.branch_long(:bcs, "rt_paint_column_large")
                asm.label("rt_paint_column_small_#{what}_kept")
              end
              asm.stz(asm.direct(c.first + 2))
              [[s.area_top, s.area_bottom, top, height, c.first, c.past, c.rows, "rows"],
               [s.area_left, s.area_right, x, width, c.across_first, c.across_past, c.across, "across"]].each do |low, high, at, size, first, past, count, what|
                asm.lda(asm.direct(low))
                asm.sec
                asm.sbc(asm.direct(at))
                asm.bpl("rt_paint_column_small_#{what}_first")
                asm.lda(0)
                asm.label("rt_paint_column_small_#{what}_first")
                asm.sta(asm.direct(first))
                asm.lda(asm.direct(high))
                asm.sec
                asm.sbc(asm.direct(at))
                asm.sta(asm.direct(past))
                asm.sec
                asm.sbc(asm.direct(size))
                asm.bmi("rt_paint_column_small_#{what}_past")
                asm.lda(asm.direct(size))
                asm.sta(asm.direct(past))
                asm.label("rt_paint_column_small_#{what}_past")
                asm.lda(asm.direct(past))
                asm.sec
                asm.sbc(asm.direct(first))
                asm.branch_long(:beq, "rt_paint_column_none")
                asm.branch_long(:bmi, "rt_paint_column_none")
                asm.sta(asm.direct(count))
              end
              asm.brl("rt_paint_column_shown")
              asm.label("rt_paint_column_large")
            end

            # +out+ (32 bits) = the area's edge at +edge+ (a word, never below nought) less the
            # place at +at+ (32 bits). A difference too big for 32 bits is as big as they go, which
            # every row and pixel across is below.
            def emit_from_edge(asm, edge, at, out, prefix)
              asm.sec
              asm.lda(asm.direct(edge))
              asm.sbc(asm.direct(at))
              asm.sta(asm.direct(out))
              asm.lda(0)
              asm.sbc(asm.direct(at + 2))
              asm.sta(asm.direct(out + 2))
              asm.bvc("#{prefix}_fits")
              asm.lda(0xFFFF)
              asm.sta(asm.direct(out))
              asm.lda(0x7FFF)
              asm.sta(asm.direct(out + 2))
              asm.label("#{prefix}_fits")
            end

            # On to +target+ unless the number at +less+ is below the one at +more+, both signed 32
            # bits (the sign of their difference, turned round where it overflowed).
            def emit_branch_unless_below(asm, less, more, target)
              asm.sec
              asm.lda(asm.direct(less))
              asm.sbc(asm.direct(more))
              asm.lda(asm.direct(less + 2))
              asm.sbc(asm.direct(more + 2))
              asm.bvc("#{target} below #{less} #{more}")
              asm.eor(0x8000)
              asm.label("#{target} below #{less} #{more}")
              asm.branch_long(:bpl, target)
            end

            # +out+ (a long address on the direct page) = the table the picture's record keeps at
            # +offset+ (RECORD_SCALERS and the rest).
            def emit_record_table(asm, record, offset, out)
              2.times do |half|
                asm.ldy(offset + (half * 2))
                asm.lda(asm.ind_long_y(record))
                asm.sta(asm.direct(out + (half * 2)))
              end
            end

            # THE CODE FOR EACH HEIGHT a column of a picture +picture_height+ rows tall can be shown
            # whole at, 1 to HEIGHT (rt_paint_column), as sections for the Linker, each height's
            # code under #scaler_label, at most +most_bytes+ to a section. The code for height h is
            # reached with A 8 bits wide, the column's places in the data bank at Y and the copy's
            # byte of the column's top in X, and for each row k reads the picture's row
            # (k × step) ÷ 65536, step being its height in 65536ths over h, as Reference walks it,
            # and writes it 8 bytes on from the row above. A row that shows the same row of the
            # picture as the row above writes what A already holds. +copy+ is where the copy is;
            # +holds+ is what the sections are counted as.
            def scaler_sections(picture_height, copy:, holds:, most_bytes:)
              sections = []
              code = nil
              (1..HEIGHT).each do |tall|
                measured = W65816.new("column scaler", holds: holds)
                emit_scaler(measured, picture_height, tall, copy)
                if code.nil? || code.here + measured.here > most_bytes
                  sections << code.section if code
                  code = W65816.new("column scalers #{picture_height} from #{tall}", holds: holds)
                end
                emit_scaler(code, picture_height, tall, copy)
              end
              sections << code.section
            end

            def scaler_label(picture_height, tall) = "column scaler #{picture_height}.#{tall}"

            def emit_scaler(asm, picture_height, tall, copy)
              step = IR::Int32.div(picture_height << Reference::FIXED, tall)
              asm.label(scaler_label(picture_height, tall))
              asm.widths(a16: false, xy16: true)
              read = nil
              tall.times do |row|
                source = ((row * step) >> Reference::FIXED).clamp(0, picture_height - 1)
                asm.lda(asm.abs_y(source)) unless source == read
                read = source
                asm.sta(asm.long_x(copy, row * ROW_STEP))
              end
              asm.rtl
            end

            # --- the patch under a sprite ---

            # The bytes a patch of +width+ × +height+ keeps (Lowering::Paint#reserve_patches): where it
            # was saved, two words with NEAR added, then a byte a pixel, row by row.
            def patch_bytes(width, height) = PATCH_HEADER_BYTES + (width * height)

            PATCH_HEADER_BYTES = 4

            # rt_paint_save(patch, x, y, w, h): the screen's pixels under the rectangle kept in the
            # patch, with where it was. rt_paint_restore(patch, x, y, w, h): the patch put back at the
            # place, inside the area. As the interpreter keeps nothing for a pixel that was off the
            # screen when it was saved (Reference#exec_save_region), such a pixel is not put back:
            # the pixels kept are worked out again from where the patch was saved, so a patch saved
            # nowhere (all nought, as work RAM starts) puts nothing back.
            #
            # On the direct page: s.pointer the patch; s.left and s.top where it was saved, s.first_x
            # and s.temp where the screen is read or written, all with NEAR; s.across and s.height its
            # width and height; s.chunk and s.not_mask the columns of it to copy, s.row and s.mask
            # the rows; s.run the byte of the patch a row starts at.
            def emit_patches(asm, memory, s, shown)
              copy = memory[COPY]
              mark = mark_scratch(s)
              asm.label("rt_paint_save")
              emit_patch_numbers(asm, s)
              emit_patch_place(asm, R.call(1), WIDTH, s.left, "rt_paint_save_x")
              emit_patch_place(asm, R.call(2), HEIGHT, s.top, "rt_paint_save_y")
              asm.ldy(0)
              asm.lda(asm.direct(s.left))
              asm.sta(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.first_x))
              asm.ldy(2)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp))
              emit_patch_kept(asm, s, "rt_paint_save_kept", shown)
              if PaintDoubledSend.behind?(memory)
                # The copy painted brought up to the other where the patch reads it.
                asm.lda(asm.direct(s.row))
                asm.cmp(asm.direct(s.mask))
                asm.bcs("rt_paint_save_fresh")
                asm.lda(asm.direct(s.chunk))
                asm.cmp(asm.direct(s.not_mask))
                asm.bcs("rt_paint_save_fresh")
                emit_patch_screen_rows(asm, s, mark)
                asm.jsr(asm.abs("rt_paint_doubled_fresh"))
                asm.label("rt_paint_save_fresh")
              end
              emit_patch_rows(asm, s, "rt_paint_save", shown) do
                asm.lda(asm.long_x(copy))
                asm.sta(asm.ind_long_y(s.pointer))
              end

              asm.label("rt_paint_restore")
              emit_patch_numbers(asm, s)
              asm.ldy(0)
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.left))
              asm.ldy(2)
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.top))
              emit_patch_kept(asm, s, "rt_paint_restore_kept", shown)
              # Where it goes, near enough the screen to put anything back, and inside the area.
              emit_near_place(asm, R.call(1), WIDTH, s.first_x, "rt_paint_restore_done")
              emit_near_place(asm, R.call(2), HEIGHT, s.temp, "rt_paint_restore_done")
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[s.area_left, s.area_right, s.first_x, s.chunk, s.not_mask, "across"],
               [s.area_top, s.area_bottom, s.temp, s.row, s.mask, "down"]].each do |low, high, place, first, past, way|
                # The first kept: past the area's edge, if that is later.
                asm.lda(asm.direct(low))
                asm.clc
                asm.adc(NEAR)
                asm.sec
                asm.sbc(asm.direct(place))
                asm.bmi("rt_paint_restore_#{way}_first")
                asm.cmp(asm.direct(first))
                asm.bcc("rt_paint_restore_#{way}_first")
                asm.sta(asm.direct(first))
                asm.label("rt_paint_restore_#{way}_first")
                # The one past the last kept: the area's far edge, if that is sooner.
                asm.lda(asm.direct(high))
                asm.clc
                asm.adc(NEAR)
                asm.sec
                asm.sbc(asm.direct(place))
                asm.branch_long(:bmi, "rt_paint_restore_done")
                asm.cmp(asm.direct(past))
                asm.bcs("rt_paint_restore_#{way}_past")
                asm.sta(asm.direct(past))
                asm.label("rt_paint_restore_#{way}_past")
              end
              # The rows and columns of tiles it changes, marked.
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.mask))
              asm.branch_long(:bcs, "rt_paint_restore_done")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(asm.direct(s.not_mask))
              asm.branch_long(:bcs, "rt_paint_restore_done")
              emit_patch_screen_rows(asm, s, mark)
              asm.jsr(asm.abs("rt_paint_doubled_mark"))
              emit_patch_rows(asm, s, "rt_paint_restore", shown) do
                asm.lda(asm.ind_long_y(s.pointer))
                asm.sta(asm.long_x(copy))
              end
            end

            # +mark+ (Mark) = the screen's rows and pixels across of the patch's rows s.row to before
            # s.mask and columns s.chunk to before s.not_mask, its top left being (s.first_x, s.temp)
            # with NEAR.
            def emit_patch_screen_rows(asm, s, mark)
              [[s.temp, s.row, mark.top], [s.temp, s.mask, mark.bottom],
               [s.first_x, s.chunk, mark.left], [s.first_x, s.not_mask, mark.right]].each do |place, part, out|
                asm.lda(asm.direct(place))
                asm.sec
                asm.sbc(NEAR)
                asm.clc
                asm.adc(asm.direct(part))
                asm.sta(asm.direct(out))
              end
            end

            # The patch's place, width and height, from the routine's numbers.
            def emit_patch_numbers(asm, s)
              [[R.call(0), s.pointer], [R.call(0) + 2, s.pointer + 2], [R.call(3), s.across], [R.call(4), s.height]].each do |from, out|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(out))
              end
            end

            # +out+ = the place at +at+ (32 bits) with NEAR added, held between nought and NEAR +
            # +edge+: a place further off the screen keeps no more of the patch than that.
            def emit_patch_place(asm, at, edge, out, prefix)
              asm.clc
              asm.lda(asm.direct(at))
              asm.adc(NEAR)
              asm.sta(asm.direct(out))
              asm.lda(asm.direct(at + 2))
              asm.adc(0)
              asm.bmi("#{prefix}_low")
              asm.bne("#{prefix}_high")
              asm.lda(asm.direct(out))
              asm.cmp(NEAR + edge + 1)
              asm.bcc("#{prefix}_kept")
              asm.label("#{prefix}_high")
              asm.lda(NEAR + edge)
              asm.sta(asm.direct(out))
              asm.bra("#{prefix}_kept")
              asm.label("#{prefix}_low")
              asm.stz(asm.direct(out))
              asm.label("#{prefix}_kept")
            end

            # The columns and rows of the patch that were on the screen where it was saved (s.left,
            # s.top), and on its rows kept (+shown+): s.chunk to before s.not_mask, s.row to before
            # s.mask.
            def emit_patch_kept(asm, s, prefix, shown)
              [[s.left, 0, WIDTH, s.across, s.chunk, s.not_mask, "across"],
               [s.top, shown.first_row, shown.past_row, s.height, s.row, s.mask, "down"]].each do |saved, low, edge, size, first, past, way|
                asm.lda(NEAR + low)
                asm.sec
                asm.sbc(asm.direct(saved))
                asm.bpl("#{prefix}_#{way}_first")
                asm.lda(0)
                asm.label("#{prefix}_#{way}_first")
                asm.sta(asm.direct(first))
                asm.lda(NEAR + edge)
                asm.sec
                asm.sbc(asm.direct(saved))
                asm.bpl("#{prefix}_#{way}_past_some")
                asm.lda(0)
                asm.label("#{prefix}_#{way}_past_some")
                asm.cmp(asm.direct(size))
                asm.bcc("#{prefix}_#{way}_past")
                asm.lda(asm.direct(size))
                asm.label("#{prefix}_#{way}_past")
                asm.sta(asm.direct(past))
              end
            end

            # The rows s.row to before s.mask of the patch, columns s.chunk to before s.not_mask, each
            # pixel copied by the block (A 8 bits wide, X the copy's byte, Y the patch's); the screen's
            # pixel of the patch's top left is (s.first_x, s.temp), with NEAR. Ends the routine.
            def emit_patch_rows(asm, s, prefix, shown)
              at = at_scratch(s)
              asm.lda(asm.direct(s.chunk))
              asm.cmp(asm.direct(s.not_mask))
              asm.branch_long(:bcs, "#{prefix}_done")
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.mask))
              asm.branch_long(:bcs, "#{prefix}_done")
              # The patch's byte for the first row's first column kept: past the header, s.row rows of
              # s.across, and s.chunk.
              asm.lda(PATCH_HEADER_BYTES)
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.ldx(asm.direct(s.row))
              asm.beq("#{prefix}_first_row")
              asm.label("#{prefix}_rows_before")
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dex
              asm.bne("#{prefix}_rows_before")
              asm.label("#{prefix}_first_row")
              asm.sta(asm.direct(s.run))
              asm.label("#{prefix}_row")
              asm.lda(asm.direct(s.first_x))
              asm.sec
              asm.sbc(NEAR)
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(at.x))
              asm.lda(asm.direct(s.temp))
              asm.sec
              asm.sbc(NEAR)
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(at.y))
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.tax
              asm.ldy(asm.direct(s.run))
              asm.lda(asm.direct(s.not_mask))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              asm.label("#{prefix}_pixel")
              asm.sep(0x20)
              yield
              asm.rep(0x20)
              asm.iny
              emit_next_byte(asm, "#{prefix}_pixel", shown)
              asm.dec(asm.direct(s.count))
              asm.bne("#{prefix}_pixel")
              asm.lda(asm.direct(s.run))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.sta(asm.direct(s.run))
              asm.inc(asm.direct(s.row))
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.mask))
              asm.bne("#{prefix}_row")
              asm.label("#{prefix}_done")
              asm.rtl
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
            def emit_blit(asm, memory, s, shown)
              copy = memory[COPY]
              mark = mark_scratch(s)
              at = at_scratch(s)
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
              emit_near_place(asm, R.call(1), WIDTH, s.across, "rt_paint_blit_none")
              emit_near_place(asm, R.call(2), HEIGHT, s.row, "rt_paint_blit_none")
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
              # The rows and columns of tiles marked changed: the picture's, inside the area. X is
              # still the picture's entry, whose width is its fifth byte.
              asm.lda(asm.direct(s.across))
              asm.cmp(asm.direct(s.left))
              asm.bcs("rt_paint_blit_mark_left")
              asm.lda(asm.direct(s.left))
              asm.label("rt_paint_blit_mark_left")
              asm.sta(asm.direct(mark.left))
              asm.lda(asm.long_x("paint pictures", 4))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.cmp(asm.direct(s.right))
              asm.bcc("rt_paint_blit_mark_right")
              asm.lda(asm.direct(s.right))
              asm.label("rt_paint_blit_mark_right")
              asm.cmp(asm.direct(mark.left)) # both still with NEAR, so they compare unsigned
              asm.beq("rt_paint_blit_rows")
              asm.bcc("rt_paint_blit_rows")
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(mark.right))
              asm.lda(asm.direct(mark.left))
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(mark.left))
              asm.lda(asm.direct(s.row))
              asm.cmp(asm.direct(s.top))
              asm.bcs("rt_paint_blit_mark_top")
              asm.lda(asm.direct(s.top))
              asm.label("rt_paint_blit_mark_top")
              asm.sta(asm.direct(mark.top))
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_blit_mark_bottom")
              asm.lda(asm.direct(s.bottom))
              asm.label("rt_paint_blit_mark_bottom")
              asm.cmp(asm.direct(mark.top))
              asm.beq("rt_paint_blit_rows")
              asm.bcc("rt_paint_blit_rows")
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(mark.bottom))
              asm.lda(asm.direct(mark.top))
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(mark.top))
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
              asm.sta(asm.direct(at.x))
              asm.lda(asm.direct(s.row))
              asm.sec
              asm.sbc(NEAR)
              asm.sta(asm.direct(at.y))
              asm.jsr(asm.abs("rt_paint_doubled_at"))
              asm.tax
              asm.label("rt_paint_blit_pixel")
              asm.sep(0x20)
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.long_x(copy))
              asm.rep(0x20)
              asm.iny
              emit_next_byte(asm, "rt_paint_blit_pixel", shown)
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

            # Every byte from 0 to 255, for a fill to send one of over and over; and where each
            # column of tiles starts in the copy, a word each (Layout#column_start).
            def emit_tables(asm, shown)
              asm.label("rt paint doubled places")
              asm.data_bytes((0..255).to_a)
              asm.label("rt paint doubled column starts")
              asm.data_words((0...COLUMNS).map { |column| shown.column_start(column) })
            end
          end
        end
      end
    end
  end
end
