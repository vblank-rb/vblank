# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A RECTANGLE IN ONE COLOUR, PAINTED BY THE SUPER FX: rt_paint_fill on a cartridge with that
          # chip. Paint's own rt_paint_fill paints the same rectangle with the console's processor,
          # and on that processor it is slow: every row of every tile it covers is eight bytes read,
          # masked and written, and every tile not yet painted this generation is first filled with
          # the clear colour, 64 bytes more, so a rectangle 20 pixels square took the console a
          # third of a frame. The chip runs at 21 MHz, eight times the console's processor, with a
          # cycle for most instructions, and its stores go on while the next instructions run.
          #
          # THE CONSOLE HANDS IT A BLOCK (ChipPaint::FILL, in the chip's RAM): the
          # rectangle's x, y, width and height as the game gave them (32 bits each), the colour's
          # place, the area painting is held to, the screen's generation and the clear colour's
          # four words of planes. Those last three live in work RAM, which the chip cannot see, so
          # they come along each time. The chip works out what Paint's rt_paint_fill works out —
          # the rectangle held to the area, its first and last tile across, the pixels of each
          # edge tile it covers, the colour's planes — and leaves the rectangle's edges in the block
          # for the console (an empty rectangle has its top at or below its bottom).
          #
          # THE CHIP MAKES EACH TILE READY AS IT REACHES IT, as Paint's rt_paint_ready does: a tile of
          # an older generation is put in this one and filled with the clear colour first, unless
          # the rectangle paints every pixel of it, and its number goes on the list of tiles readied
          # (ChipPaint::READIED), which the console reads after the run to point each one's cell of
          # the map back at it. The console also marks each row of tiles the rectangle covers as
          # changed (Paint's DIRTY), which is in work RAM too.
          #
          # HOW IT PAINTS. A band at a time, a band being the rectangle's rows inside one row of
          # tiles; across the band a tile at a time; in each tile a pair of planes at a time, down
          # the band's rows with LOOP. A tile the rectangle covers all across is written without
          # being read (SOLID); an edge tile is read, its pixels outside the rectangle kept and the
          # rest written (MASKED).
          #
          # THE CHIP'S QUICK MEMORY. Code the chip runs from its 512-byte cache takes a cycle a byte,
          # and from the ROM five; filling the cache is five a byte too, once. CACHE starts it at the
          # entry and the code comes in the order of how often it runs: the band's code, then the
          # two routines setting up calls more than once, then what runs once a rectangle (SETUP),
          # whose end is past the cache. The cache lasts from one rectangle to the next while
          # nothing else runs on the chip (Chip's rt_chip_run leaves the bank the chip reads its
          # code from alone when it is already this one, since setting it empties the cache).
          module ChipFill
            ENTRY = "chip fill"
            BAND = "chip fill band"
            SETUP = "chip fill setup"
            CLAMP = "chip fill clamp"
            MASK_OF = "chip fill mask of"

            # The block, as offsets from its start. What the console writes: for each axis, the
            # rectangle's left (or top) and its width (or height), 32 bits each, and the area's two
            # edges (right and bottom just past it), followed by where the chip leaves the
            # rectangle's two edges held to the area; then the colour's place, the generation and
            # the clear colour's planes. What else the chip leaves for the console: the first and
            # last tile across. What the chip keeps for itself: the colour's planes, the first and
            # last tiles' masks, the row a band starts on, the row past its end, where its first
            # row starts in the picture, its first tile's number, and whether it is a whole row of
            # tiles.
            OFFSETS = %i[x x_high width width_high area_left area_right left right
                         y y_high height height_high area_top area_bottom top bottom
                         place generation clear0 clear1 clear2 clear3 first_tile last_tile
                         planes0 planes1 planes2 planes3 left_mask right_mask
                         band_top band_end row_start tile_row whole].each_with_index.to_h { |what, i| [what, i * 2] }.freeze
            BYTES = OFFSETS.length * 2
            # Where each 16-bit half of a 32-bit number is.
            HALVES = [0, 2].freeze
            raise "the chip's fill block is #{BYTES} bytes, over #{ChipPaint::FILL_BYTES}" if BYTES > ChipPaint::FILL_BYTES

            module_function

            # The 16-bit place in the chip's RAM of +what+ in the block.
            def block_place(what) = ChipPaint::FILL - ChipPaint::COPY + OFFSETS.fetch(what)

            # Its long address, as the console reaches it.
            def block_address(what) = ChipPaint::FILL + OFFSETS.fetch(what)

            # --- the console's side ---

            # rt_paint_fill(x, y, w, h, place), for a cartridge with the chip: the block handed over,
            # the chip run, and what it changed of work RAM's copy of the painted screen brought up
            # to date. +s+ is Paint's scratch.
            def emit_console(asm, memory, s)
              r = Paint::R
              asm.label("rt_paint_fill")
              %i[x y width height].each_with_index do |what, number|
                HALVES.each do |half|
                  asm.lda(asm.direct(r.call(number) + half))
                  asm.sta(asm.long(block_address(what) + half))
                end
              end
              asm.lda(asm.direct(r.call(4)))
              asm.sta(asm.long(block_address(:place)))
              %i[area_left area_top area_right area_bottom].each_with_index do |what, i|
                asm.lda(asm.abs(memory[Paint::AREA] + (i * 2)))
                asm.sta(asm.long(block_address(what)))
              end
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.sta(asm.long(block_address(:generation)))
              4.times do |pair|
                asm.lda(asm.abs(memory[Paint::CLEAR_PLANES] + (pair * 2)))
                asm.sta(asm.long(block_address(:"clear#{pair}")))
              end
              asm.lda(asm.imm(ENTRY))
              asm.sta(asm.direct(r.call(0)))
              asm.lda(asm.bank_of(ENTRY))
              asm.and_a(0x00FF) # the fourth byte nought: the run plots nothing
              asm.sta(asm.direct(r.call(0) + 2))
              asm.jsl(asm.long("rt_chip_run"))
              asm.lda(asm.long(block_address(:bottom)))
              asm.sta(asm.direct(s.bottom))
              asm.lda(asm.long(block_address(:top)))
              asm.sta(asm.direct(s.top))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_fill_painted")
              asm.rtl
              asm.label("rt_paint_fill_painted")
              asm.lda(asm.long(block_address(:first_tile)))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.long(block_address(:last_tile)))
              asm.sta(asm.direct(s.last))
              emit_dirty_rows_update(asm, memory, s)
              emit_readied_map_cells(asm, memory, s)
              asm.rtl
            end

            # Each row of tiles from +top+ to +bottom+ said changed from tile +chunk+ to +last+, as
            # Paint's rt_paint_mark says it.
            def emit_dirty_rows_update(asm, memory, s, prefix = "rt_paint_fill")
              dirty = memory[Paint::DIRTY]
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.label("#{prefix}_row_changed")
              asm.sta(asm.direct(s.mark_row))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.chunk))
              asm.cmp(asm.abs_x(dirty))
              asm.bcs("#{prefix}_left_kept")
              asm.sta(asm.abs_x(dirty))
              asm.label("#{prefix}_left_kept")
              asm.lda(asm.direct(s.last))
              asm.cmp(asm.abs_x(dirty + 2))
              asm.bcc("#{prefix}_right_kept")
              asm.sta(asm.abs_x(dirty + 2))
              asm.label("#{prefix}_right_kept")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.direct(s.temp))
              asm.inc # INC leaves the carry as the comparison set it
              asm.bcc("#{prefix}_row_changed")
            end

            # Each tile the chip made ready has its cell of the map pointed back at it, as Paint's
            # rt_paint_ready does.
            def emit_readied_map_cells(asm, memory, s, prefix = "rt_paint_fill")
              asm.lda(asm.long(ChipPaint::READIED_COUNT))
              asm.beq("#{prefix}_none_readied")
              asm.sta(asm.direct(s.count))
              asm.ldx(0)
              asm.label("#{prefix}_readied")
              asm.phx
              asm.lda(asm.long_x(ChipPaint::READIED))
              asm.pha
              asm.asl
              asm.tax
              asm.pla
              asm.sta(asm.long_x(memory[Paint::MAP_COPY]))
              asm.plx
              asm.inx
              asm.inx
              asm.cpx(asm.direct(s.count))
              asm.bne("#{prefix}_readied")
              asm.lda(1)
              asm.sta(asm.abs(memory[Paint::MAP_CHANGED]))
              asm.label("#{prefix}_none_readied")
            end

            # --- the chip's side ---

            # Registers of the band's code: the tile across (COLUMN), the band's rows (ROWS), the
            # place a pair of planes is written at (AT), the tile's mask and then its opposite (MASK),
            # the colour's planes held to the mask (HELD), the start of the tile's row in the picture
            # (TILE_AT), the planes' place in the block (PLANES), how many pairs are left (PAIRS),
            # sixteen (SIXTEEN), and the tile's number (TILE).
            SIXTEEN = 1
            PAIRS = 3
            PLANES = 4
            AT = 5
            MASK = 6
            HELD = 7
            COLUMN = 8
            TILE_AT = 9
            ROWS = 10
            TILE = 2

            GENERATIONS = ChipPaint::GENERATIONS - ChipPaint::COPY
            READIED_COUNT = ChipPaint::READIED_COUNT - ChipPaint::COPY
            READIED = ChipPaint::READIED - ChipPaint::COPY

            # The chip's program, as a section for the Linker.
            def section
              gsu = GSU.new("chip fill")
              gsu.label(ENTRY)
              gsu.cache
              emit_jump(gsu, SETUP)
              emit_band(gsu)
              emit_clamp(gsu)
              emit_mask_of(gsu)
              emit_setup(gsu)
              gsu.section
            end

            def emit_jump(gsu, label)
              gsu.iwt(15, label)
              gsu.nop
            end

            # One band: its rows, where its first row starts, and each tile across it.
            def emit_band(gsu)
              gsu.label(BAND)
              gsu.lm(0, block_place(:band_top))
              # The band ends at the foot of its row of tiles, or at the rectangle's bottom.
              gsu.iwt(1, 0xFFF8)
              gsu.from(0).to(2).and_(1)
              gsu.with(2).add(gsu.imm(8))
              gsu.lm(3, block_place(:bottom))
              gsu.from(2).cmp(3)
              gsu.bcc("chip fill band end")
              gsu.nop
              gsu.move(2, 3)
              gsu.label("chip fill band end")
              gsu.sm(block_place(:band_end), 2)
              gsu.from(2).to(ROWS).sub(0)
              # Where its first row starts: its row of tiles × 2048, and two bytes a row into the tile.
              gsu.from(0).to(3).and_(1)
              gsu.from(3).to(4).swap
              gsu.from(0).to(5).and_(gsu.imm(7))
              gsu.with(4).add(5)
              gsu.with(4).add(5)
              gsu.sm(block_place(:row_start), 4)
              # Its first tile's number, its row of tiles × 32.
              gsu.with(3).add(3)
              gsu.with(3).add(3)
              gsu.sm(block_place(:tile_row), 3)
              # A band of a whole row of tiles: it starts at a tile's top and is eight rows.
              gsu.ibt(0, 0)
              gsu.moves(5, 5)
              gsu.bne("chip fill band known")
              gsu.nop
              gsu.ibt(1, 8)
              gsu.from(ROWS).cmp(1)
              gsu.bne("chip fill band known")
              gsu.nop
              gsu.ibt(0, 1)
              gsu.label("chip fill band known")
              gsu.sm(block_place(:whole), 0)
              gsu.lm(COLUMN, block_place(:first_tile))
              emit_tile(gsu)
              # The next band, unless that was the last.
              gsu.lm(0, block_place(:band_end))
              gsu.sm(block_place(:band_top), 0)
              gsu.lm(1, block_place(:bottom))
              gsu.cmp(1)
              gsu.bcs("chip fill done")
              gsu.nop
              emit_jump(gsu, BAND)
              gsu.label("chip fill done")
              gsu.stop
            end

            # Tile COLUMN of the band, made ready and painted, and the tiles after it to the last.
            def emit_tile(gsu)
              gsu.label("chip fill tile")
              emit_mask(gsu)
              emit_ready(gsu)
              emit_paint(gsu)
              gsu.inc(COLUMN)
              gsu.lm(0, block_place(:last_tile))
              gsu.from(0).cmp(COLUMN)
              gsu.bcc("chip fill tiles done")
              gsu.nop
              emit_jump(gsu, "chip fill tile")
              gsu.label("chip fill tiles done")
            end

            # MASK: the first tile's mask, the last tile's, or every pixel for a tile between.
            def emit_mask(gsu)
              gsu.iwt(MASK, 0xFFFF)
              gsu.lm(0, block_place(:first_tile))
              gsu.from(COLUMN).cmp(0)
              gsu.bne("chip fill not first")
              gsu.nop
              gsu.lm(MASK, block_place(:left_mask))
              gsu.bra("chip fill mask known")
              gsu.nop
              gsu.label("chip fill not first")
              gsu.lm(0, block_place(:last_tile))
              gsu.from(COLUMN).cmp(0)
              gsu.bne("chip fill mask known")
              gsu.nop
              gsu.lm(MASK, block_place(:right_mask))
              gsu.label("chip fill mask known")
            end

            # The tile made ready if it is of an older generation: put in this one, put on the list
            # of tiles readied, and filled with the clear colour unless this paints all of it (a
            # band of a whole row of tiles, and every pixel of the mask).
            def emit_ready(gsu)
              gsu.lm(TILE, block_place(:tile_row))
              gsu.with(TILE).add(COLUMN)
              emit_tile_ready_if_old(gsu, "chip fill", generation: block_place(:generation), clear: block_place(:clear0)) do
                gsu.lm(0, block_place(:whole))
                gsu.moves(0, 0)
                gsu.beq("chip fill clear tile")
                gsu.nop
                gsu.from(MASK).to(0).not_
                gsu.moves(0, 0)
                gsu.beq("chip fill ready")
                gsu.nop
              end
            end

            # Tile TILE made ready, if its generation is not the word at +generation+: put in that
            # generation and on the list of tiles readied, and its 64 bytes filled with the clear
            # colour's four words of planes at +clear+ — unless the block given, which may branch to
            # "+tag+ ready", says the tile is painted whole. Uses R0, R1, AT, HELD, PAIRS, R12, R13.
            def emit_tile_ready_if_old(gsu, tag, generation:, clear:)
              gsu.iwt(AT, GENERATIONS)
              gsu.with(AT).add(TILE)
              gsu.ldb(AT)
              gsu.lm(1, generation)
              gsu.from(0).cmp(1)
              gsu.beq("#{tag} ready")
              gsu.nop
              gsu.from(1).stb(AT)
              gsu.lm(0, READIED_COUNT)
              gsu.iwt(AT, READIED)
              gsu.with(AT).add(0)
              gsu.from(TILE).stw(AT)
              gsu.add(gsu.imm(2))
              gsu.sm(READIED_COUNT, 0)
              yield if block_given?
              gsu.label("#{tag} clear tile")
              gsu.move(AT, TILE)
              6.times { gsu.with(AT).add(AT) }
              gsu.iwt(HELD, clear)
              gsu.ibt(PAIRS, 4)
              gsu.label("#{tag} clear pair")
              gsu.ldw(HELD)
              gsu.ibt(12, 8)
              gsu.iwt(13, "#{tag} clear row")
              gsu.label("#{tag} clear row")
              gsu.stw(AT)
              gsu.inc(AT)
              gsu.loop
              gsu.inc(AT)
              gsu.inc(HELD)
              gsu.inc(HELD)
              gsu.dec(PAIRS)
              gsu.bne("#{tag} clear pair")
              gsu.nop
              gsu.label("#{tag} ready")
            end

            # The band's rows of the tile, a pair of planes at a time: written straight where the
            # mask is every pixel, read and kept outside it where it is not.
            def emit_paint(gsu)
              gsu.move(TILE_AT, COLUMN)
              6.times { gsu.with(TILE_AT).add(TILE_AT) }
              gsu.lm(0, block_place(:row_start))
              gsu.with(TILE_AT).add(0)
              gsu.iwt(PLANES, block_place(:planes0))
              gsu.ibt(PAIRS, 4)
              gsu.ibt(SIXTEEN, 16)
              gsu.from(MASK).to(MASK).not_
              gsu.moves(MASK, MASK)
              gsu.bne("chip fill masked pair")
              gsu.nop
              gsu.label("chip fill solid pair")
              gsu.ldw(PLANES)
              gsu.move(AT, TILE_AT)
              gsu.move(12, ROWS)
              gsu.iwt(13, "chip fill solid row")
              gsu.label("chip fill solid row")
              gsu.stw(AT)
              gsu.inc(AT)
              gsu.loop
              gsu.inc(AT)
              gsu.inc(PLANES)
              gsu.inc(PLANES)
              gsu.with(TILE_AT).add(SIXTEEN)
              gsu.dec(PAIRS)
              gsu.bne("chip fill solid pair")
              gsu.nop
              gsu.bra("chip fill painted")
              gsu.nop
              gsu.label("chip fill masked pair")
              gsu.ldw(PLANES)
              gsu.to(HELD).bic(MASK)
              gsu.move(AT, TILE_AT)
              gsu.move(12, ROWS)
              gsu.iwt(13, "chip fill masked row")
              gsu.label("chip fill masked row")
              gsu.ldw(AT)
              gsu.and_(MASK)
              gsu.or_(HELD)
              gsu.stw(AT)
              gsu.inc(AT)
              gsu.loop
              gsu.inc(AT)
              gsu.inc(PLANES)
              gsu.inc(PLANES)
              gsu.with(TILE_AT).add(SIXTEEN)
              gsu.dec(PAIRS)
              gsu.bne("chip fill masked pair")
              gsu.nop
              gsu.label("chip fill painted")
            end

            # Once a rectangle: its edges held to the area, nothing painted when it is empty, its
            # first and last tile across and their masks, the colour's planes, and the first band.
            # The block keeps each axis's numbers in the order they are read, and its edges after
            # them, so the two axes are one walk down it.
            def emit_setup(gsu)
              gsu.label(SETUP)
              gsu.ibt(0, 0)
              gsu.sm(READIED_COUNT, 0)
              gsu.iwt(9, block_place(:x))
              gsu.ibt(8, 2)
              gsu.label("chip fill axis")
              # R1:R2 the left (or top), R5:R6 the width (or height), R3 and R4 the area's edges.
              [1, 2, 5, 6, 3, 4].each do |register|
                gsu.to(register).ldw(9)
                gsu.inc(9)
                gsu.inc(9)
              end
              gsu.with(5).add(1)
              gsu.with(6).adc(2)
              emit_call(gsu, CLAMP)
              gsu.stw(9)
              gsu.inc(9)
              gsu.inc(9)
              gsu.move(1, 5)
              gsu.move(2, 6)
              emit_call(gsu, CLAMP)
              gsu.stw(9)
              gsu.inc(9)
              gsu.inc(9)
              gsu.dec(8)
              gsu.bne("chip fill axis")
              gsu.nop
              # Nothing to paint unless the left is before the right and the top above the bottom.
              # For the console, an empty rectangle has its bottom at its top.
              gsu.lm(0, block_place(:left))
              gsu.lm(1, block_place(:right))
              gsu.cmp(1)
              gsu.bcc("chip fill across")
              gsu.nop
              gsu.lm(0, block_place(:top))
              gsu.sm(block_place(:bottom), 0)
              gsu.stop
              gsu.label("chip fill across")
              gsu.lm(0, block_place(:top))
              gsu.lm(1, block_place(:bottom))
              gsu.cmp(1)
              gsu.bcc("chip fill down")
              gsu.nop
              gsu.stop
              gsu.label("chip fill down")
              gsu.sm(block_place(:band_top), 0)
              [[:left, :first_tile, :left_mask], [:right, :last_tile, :right_mask]].each do |edge, tile, mask|
                gsu.lm(3, block_place(edge))
                gsu.dec(3) if edge == :right
                3.times { gsu.with(3).lsr }
                gsu.sm(block_place(tile), 3)
                3.times { gsu.with(3).add(3) }
                emit_call(gsu, MASK_OF)
                gsu.sm(block_place(mask), 0)
              end
              emit_planes(gsu)
              emit_jump(gsu, BAND)
            end

            def emit_call(gsu, label)
              gsu.link(4)
              gsu.iwt(15, label)
              gsu.nop
            end

            def emit_return(gsu)
              gsu.jmp(11)
              gsu.nop
            end

            # CLAMP (LINK): R0 = the 32-bit number in R1:R2 held between R3 and R4, two small numbers,
            # nought or more (Paint's emit_clamp): R3 when it is below R3, R4 when it is R4 or past.
            def emit_clamp(gsu)
              gsu.label(CLAMP)
              gsu.moves(2, 2)
              gsu.bmi("chip fill clamp low")
              gsu.nop
              gsu.bne("chip fill clamp high")
              gsu.nop
              gsu.from(1).cmp(3)
              gsu.bcc("chip fill clamp low")
              gsu.nop
              gsu.from(1).cmp(4)
              gsu.bcs("chip fill clamp high")
              gsu.nop
              gsu.move(0, 1)
              emit_return(gsu)
              gsu.label("chip fill clamp low")
              gsu.move(0, 3)
              emit_return(gsu)
              gsu.label("chip fill clamp high")
              gsu.move(0, 4)
              emit_return(gsu)
            end

            # MASK_OF (LINK), or +label+: R0 = the pixels of the tile whose left edge is R3 that are
            # between the words at +left+ and +right+ (the rectangle's, unless said), a byte with the
            # top bit leftmost, in both bytes of the word (Paint's rt_paint_column_mask): those from
            # the left less R3 (nought at least) up to the right less R3 (eight at most). The tile is
            # one painted, so its left edge is before the right and the left before its right edge.
            def emit_mask_of(gsu, label = MASK_OF, left: block_place(:left), right: block_place(:right))
              gsu.label(label)
              # R1 = the pixels from the left on.
              gsu.iwt(1, 0xFF)
              gsu.lm(0, left)
              gsu.from(0).to(12).sub(3)
              gsu.bcc("#{label} from known") # the left is before this tile: every pixel from its edge
              gsu.nop
              gsu.moves(12, 12)
              gsu.beq("#{label} from known")
              gsu.nop
              gsu.iwt(13, "#{label} from")
              gsu.label("#{label} from")
              gsu.with(1).lsr
              gsu.loop
              gsu.nop
              gsu.label("#{label} from known")
              # R2 = $FF00 moved right by how many pixels are before the right: its low byte is them.
              gsu.iwt(2, 0xFF00)
              gsu.lm(0, right)
              gsu.from(0).to(12).sub(3)
              gsu.ibt(0, 8)
              gsu.from(12).cmp(0)
              gsu.bcc("#{label} to")
              gsu.nop
              gsu.move(12, 0)
              gsu.label("#{label} to")
              gsu.iwt(13, "#{label} to shift")
              gsu.label("#{label} to shift")
              gsu.with(2).lsr
              gsu.loop
              gsu.nop
              gsu.from(1).to(0).and_(2)
              gsu.lob
              gsu.from(0).to(1).swap
              gsu.or_(1)
              emit_return(gsu)
            end

            # Each pair of the colour's planes, from its place: a byte of $FF for each bit set, the
            # bits taken from the bottom as LSR shifts them out.
            def emit_planes(gsu)
              gsu.lm(3, block_place(:place))
              gsu.iwt(9, block_place(:planes0))
              gsu.ibt(8, 4)
              gsu.label("chip fill planes")
              gsu.ibt(0, 0)
              [[0, 0x00FF], [1, 0xFF00]].each do |half, bits|
                gsu.with(3).lsr
                gsu.bcc("chip fill plane #{half}")
                gsu.nop
                gsu.iwt(1, bits)
                gsu.or_(1)
                gsu.label("chip fill plane #{half}")
              end
              gsu.stw(9)
              gsu.inc(9)
              gsu.inc(9)
              gsu.dec(8)
              gsu.bne("chip fill planes")
              gsu.nop
            end
          end
        end
      end
    end
  end
end
