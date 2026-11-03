# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PICTURE'S COLUMN STRETCHED DOWN THE SCREEN, ON THE SUPER FX: the walls of a first-person
          # view, painted by the chip (a cartridge with that chip, a routine marked `on_chip: true`).
          #
          # ChipCode works out everything about a column that takes a 32-bit sum, as the 65816's
          # lowering does (Lowering::Paint#emit_column_walk): which rows of it are on the screen and
          # inside the area, how far down the picture each row of the screen goes, and where the
          # picture's column is in the cartridge. Then it calls this routine once for each column of
          # the screen the strip covers, with every number it needs in a word of the chip's RAM
          # (Places). From here on everything fits in 16 bits: an x across the screen, a first row
          # down it, how many rows, and the walk down the picture in 65536ths.
          #
          # THE PICTURE IS PAINT'S, in the chip's RAM (ChipPaint): tiles of eight bits a pixel, 32 to
          # a row of them, each keeping its pixels in planes. So one pixel is a bit in each of four
          # words, a row of the tile's planes 0 and 1, 2 and 3, 4 and 5, 6 and 7, sixteen bytes apart.
          # A column is one bit of each word all the way down: the routine keeps a MASK of that bit
          # (in both bytes), the colour's four words held to the mask, and paints a row as four reads,
          # four ANDs with the mask's opposite, four ORs with the colour and four writes. The colour's
          # words come from a table of all 256 places (PLANES, eight bytes a place), read only when
          # the walk moves on to another row of the picture, which a wall up close does once in many
          # rows of the screen.
          #
          # A SEE-THROUGH PIXEL leaves the screen as it was: its mask's opposite is every bit and its
          # colour nothing, so the row is written back as it was read.
          #
          # FIRST, THE TILES THE COLUMN CROSSES ARE MADE READY, as Paint's rt_paint_mark does. A tile
          # of an older generation is the clear colour throughout whatever its bytes say, so before
          # any of it is painted its 64 bytes are made the clear colour's and its generation this
          # one. Such a tile's cell of the map, in work RAM, still shows the clear tile, which the
          # chip cannot change: the tile goes on the list READIED, and the console points its cell
          # back at it when the chip stops (Lowering::Chip). Each row of tiles keeps the leftmost and
          # rightmost tile changed since the last blank (Paint's DIRTY), which the console copies in
          # before the run and back after.
          module ChipColumns
            ROUTINE = "chip paint column"
            PLANES = "chip paint planes"

            # The 16-bit places in the chip's RAM the routine reads: the column's +x+ on the screen,
            # its first row +y+ and how many +rows+, where the walk down the picture stands at the
            # first row (+at+, 65536ths of a row, low half first) and how far it goes each row
            # (+step+), the picture's column in the cartridge (+texels+, the address in its bank, and
            # +texel_bank+), where the routine keeps its way back (+back+); and what the console hands
            # it of the painted screen: the screen's +generation+, the clear colour's four words of
            # planes (+clear+), each row of tiles' leftmost and rightmost changed tile (+dirty+), and
            # the tiles made ready (+readied+, after +readied_count+, the bytes of it in use).
            Places = Data.define(:x, :y, :rows, :at, :step, :texels, :texel_bank, :back, :generation, :clear, :dirty,
                                 :readied_count, :readied)

            # The generations' place as the chip counts it, from the start of its RAM.
            GENERATIONS = ChipPaint::GENERATIONS - ChipPaint::COPY

            # The registers the walk keeps: the step, where it stands, the place in RAM of the row
            # at hand (its planes 0 and 1), the mask and its opposite, the colour's four words, the
            # rows left, and where it goes to read another row of the picture.
            STEP_LOW = 1
            STEP_HIGH = 2
            AT_LOW = 3
            AT_HIGH = 4
            ROW = 5
            MASK = 6
            KEEP = 7
            COLOUR = [8, 9, 10, 11].freeze
            ROWS_LEFT = 12
            FETCH = 13

            # Moving down a row of the screen from the last pair of planes (48 bytes on): two bytes on
            # inside a tile, or to the top row of the tile below, a row of 32 tiles on.
            DOWN_INSIDE = 2 - 48
            DOWN_TO_NEXT_TILE = (Paint::COLUMNS * Paint::TILE_BYTES) - 14 - 48

            module_function

            # The routine, and the table of places' planes, into +gsu+.
            def emit(gsu, places)
              gsu.label(ROUTINE)
              gsu.sm(places.back, 11)
              gsu.cache
              emit_ready_tiles(gsu, places)
              emit_walk(gsu, places)
              gsu.lm(11, places.back)
              gsu.jmp(11)
              gsu.nop
              emit_planes(gsu)
            end

            # The registers of the tiles' walk.
            COLUMN = 1
            TILE_ROW = 2
            LAST_ROW = 3
            TILE = 4
            AT = 5
            PAIRS = 6
            CLEAR = 7
            GENERATION = 8

            def emit_ready_tiles(gsu, places)
              gsu.lm(0, places.x)
              3.times { gsu.lsr }
              gsu.move(COLUMN, 0)
              gsu.lm(TILE_ROW, places.y)
              gsu.lm(LAST_ROW, places.rows)
              gsu.with(LAST_ROW)
              gsu.add(TILE_ROW)
              gsu.dec(LAST_ROW)
              [TILE_ROW, LAST_ROW].each { |register| 3.times { gsu.with(register).lsr } }
              gsu.lm(GENERATION, places.generation)
              gsu.label("chip column tile")
              # TILE = TILE_ROW * 32 + COLUMN
              gsu.move(TILE, TILE_ROW)
              5.times { gsu.with(TILE).add(TILE) }
              gsu.with(TILE).add(COLUMN)
              emit_mark_changed(gsu, places)
              gsu.iwt(AT, GENERATIONS)
              gsu.with(AT).add(TILE)
              gsu.ldb(AT)
              gsu.from(0).cmp(GENERATION)
              gsu.beq("chip column tile ready")
              gsu.nop
              gsu.from(GENERATION).stb(AT)
              emit_clear_tile(gsu, places)
              gsu.lm(0, places.readied_count)
              gsu.iwt(AT, places.readied)
              gsu.with(AT).add(0)
              gsu.from(TILE).stw(AT)
              gsu.add(gsu.imm(2))
              gsu.sm(places.readied_count, 0)
              gsu.label("chip column tile ready")
              gsu.from(TILE_ROW).cmp(LAST_ROW)
              gsu.beq("chip column tiles ready")
              gsu.nop
              gsu.inc(TILE_ROW)
              gsu.iwt(15, "chip column tile")
              gsu.nop
              gsu.label("chip column tiles ready")
            end

            # The row of tiles' leftmost changed tile made COLUMN if it is further right, and its
            # rightmost if it is further left.
            def emit_mark_changed(gsu, places)
              gsu.move(AT, TILE_ROW)
              2.times { gsu.with(AT).add(AT) }
              gsu.iwt(0, places.dirty)
              gsu.with(AT).add(0)
              gsu.ldw(AT)
              gsu.from(COLUMN).cmp(0)
              gsu.bcs("chip column left kept")
              gsu.nop
              gsu.from(COLUMN).stw(AT)
              gsu.label("chip column left kept")
              gsu.inc(AT)
              gsu.inc(AT)
              gsu.ldw(AT)
              gsu.from(0).cmp(COLUMN)
              gsu.bcs("chip column right kept")
              gsu.nop
              gsu.from(COLUMN).stw(AT)
              gsu.label("chip column right kept")
            end

            # TILE's 64 bytes the clear colour: each of its eight rows the clear colour's four words.
            def emit_clear_tile(gsu, places)
              gsu.move(AT, TILE)
              6.times { gsu.with(AT).add(AT) }
              gsu.iwt(CLEAR, places.clear)
              gsu.ibt(PAIRS, 4)
              gsu.label("chip column clear pair")
              gsu.ldw(CLEAR)
              8.times do
                gsu.stw(AT)
                gsu.inc(AT)
                gsu.inc(AT)
              end
              gsu.inc(CLEAR)
              gsu.inc(CLEAR)
              gsu.dec(PAIRS)
              gsu.bne("chip column clear pair")
              gsu.nop
            end

            def emit_walk(gsu, places)
              emit_mask(gsu, places)
              emit_first_row_place(gsu, places)
              gsu.lm(STEP_LOW, places.step)
              gsu.lm(STEP_HIGH, places.step + 2)
              gsu.lm(AT_LOW, places.at)
              gsu.lm(AT_HIGH, places.at + 2)
              gsu.lm(ROWS_LEFT, places.rows)
              gsu.iwt(FETCH, "chip column fetch")
              emit_fetch(gsu, places)
              emit_rows(gsu)
            end

            # MASK the column's bit in both bytes: the top bit for the tile's leftmost pixel.
            def emit_mask(gsu, places)
              gsu.iwt(MASK, 0x8080)
              gsu.lm(0, places.x)
              gsu.and_(gsu.imm(7))
              gsu.beq("chip column masked")
              gsu.nop
              gsu.label("chip column mask")
              gsu.with(MASK).lsr
              gsu.dec(0)
              gsu.bne("chip column mask")
              gsu.nop
              gsu.label("chip column masked")
            end

            # ROW at the first row's planes 0 and 1: its row of tiles × 2048, its tile across × 64,
            # and two bytes a row of pixels down the tile.
            def emit_first_row_place(gsu, places)
              gsu.lm(ROW, places.y)
              3.times { gsu.with(ROW).lsr }
              gsu.with(ROW).swap
              3.times { gsu.with(ROW).add(ROW) }
              gsu.lm(0, places.x)
              3.times { gsu.lsr }
              6.times { gsu.add(0) }
              gsu.with(ROW).add(0)
              gsu.lm(0, places.y)
              gsu.and_(gsu.imm(7))
              gsu.add(0)
              gsu.with(ROW).add(0)
            end

            # The picture's row AT_HIGH read: its place, then that place's four words of planes held
            # to the mask, or nothing to paint for a see-through place. Writing R14 starts a read of
            # the cartridge, GETB takes it, and an INC of R14 starts the next.
            def emit_fetch(gsu, places)
              gsu.label("chip column fetch")
              gsu.lm(0, places.texel_bank)
              gsu.romb
              gsu.lm(0, places.texels)
              gsu.from(0).to(14).add(AT_HIGH)
              gsu.getb
              gsu.from(0).to(COLOUR[0]).add(gsu.imm(1))
              gsu.with(COLOUR[0]).hib
              gsu.beq("chip column opaque")
              gsu.nop
              gsu.ibt(KEEP, -1)
              COLOUR.each { |register| gsu.ibt(register, 0) }
              gsu.bra("chip column row")
              gsu.nop
              gsu.label("chip column opaque")
              3.times { gsu.add(0) }
              gsu.ibt_bank_of(COLOUR[0], PLANES)
              gsu.from(COLOUR[0]).romb
              gsu.iwt(COLOUR[0], PLANES)
              gsu.from(COLOUR[0]).to(14).add(0)
              COLOUR.each_with_index do |register, number|
                gsu.to(register).getb
                gsu.inc(14)
                gsu.with(register).getbh
                gsu.inc(14) unless number == COLOUR.length - 1
              end
              COLOUR.each { |register| gsu.with(register).and_(MASK) }
              gsu.from(MASK).to(KEEP).not_
            end

            # A row painted, ROW moved down a row of the screen, and the walk moved on: the picture's
            # row read again only when it is another.
            def emit_rows(gsu)
              gsu.label("chip column row")
              COLOUR.each_with_index do |register, pair|
                gsu.ldw(ROW)
                gsu.and_(KEEP)
                gsu.or_(register)
                gsu.stw(ROW)
                next if pair == COLOUR.length - 1

                gsu.with(ROW).add(gsu.imm(15))
                gsu.inc(ROW)
              end
              gsu.from(ROW).to(0).and_(gsu.imm(14))
              gsu.sub(gsu.imm(14))
              gsu.bne("chip column inside tile")
              gsu.nop
              gsu.iwt(0, DOWN_TO_NEXT_TILE)
              gsu.bra("chip column moved down")
              gsu.nop
              gsu.label("chip column inside tile")
              gsu.ibt(0, DOWN_INSIDE)
              gsu.label("chip column moved down")
              gsu.with(ROW).add(0)
              gsu.dec(ROWS_LEFT)
              gsu.beq("chip column done")
              gsu.nop
              gsu.move(0, AT_HIGH)
              gsu.with(AT_LOW).add(STEP_LOW)
              gsu.with(AT_HIGH).adc(STEP_HIGH)
              gsu.from(AT_HIGH).cmp(0)
              gsu.beq("chip column row")
              gsu.nop
              gsu.jmp(FETCH)
              gsu.nop
              gsu.label("chip column done")
            end

            # For each of the 256 places, its four words of planes: in each, $FF in the low byte for
            # the even plane's bit set and in the high byte for the odd one's.
            def emit_planes(gsu)
              gsu.label(PLANES)
              gsu.data_bytes((0..255).flat_map { |place| (0..7).map { |plane| place[plane] == 1 ? 0xFF : 0 } })
            end
          end
        end
      end
    end
  end
end
