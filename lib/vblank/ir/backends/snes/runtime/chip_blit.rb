# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PICTURE PAINTED BY THE SUPER FX: rt_paint_blit on a cartridge with that chip, and so
          # text too, which is pictures on a painted screen there. The console works out what is
          # quick to work out (Paint's rt_paint_blit, up to the tiles across: the rows inside the
          # area and the tiles across them) and hands it over; the chip makes the tiles ready and
          # paints the picture's rows into them, as Paint's rows and ChipFill's tiles are painted.
          #
          # THE PICTURE IS IN THE CARTRIDGE, where SNES::PaintedArt keeps it: a table of where each
          # of its rows is (four bytes a row, its address and bank), and each row its runs, one for
          # each place across modulo eight it can be painted at, of a COLUMN of ten bytes for each tile across:
          # the mask of the pixels it draws in both bytes of a word, then its four pairs of planes,
          # each pair a word: ready to write into a tile's row. The chip reads
          # the cartridge a byte at a time: R14 says where, ROMB which bank, and GETB takes the byte
          # a few cycles after R14 was written, so the reads go one after another down a column.
          #
          # HOW IT PAINTS. A band at a time, a band being the picture's rows inside one row of tiles:
          # first each tile of the band across is made ready (ChipFill#emit_tile_ready_if_old, every
          # one filled with the clear colour, since a picture can leave pixels as they were), then
          # each row: where it is in the cartridge, then each tile's column of it, its mask held to
          # the area at the first and last tile, written into the tile's row through the mask.
          module ChipBlit
            ENTRY = "chip blit"
            BAND = "chip blit band"
            SETUP = "chip blit setup"
            MASK_OF = "chip blit mask of"

            # The block (ChipPaint::BLIT), as offsets from its start. What the console writes: where
            # the picture's table of rows is (its address, then its bank), how many tiles across a
            # row of it reaches, where in a row the run for its place across modulo eight starts
            # (Paint's +run+, read from SNES::PaintedArt#run_starts), its place down, its first tile across counted from the screen's left (less than nought when it starts
            # off the screen), the first and last tile painted, the top and bottom rows painted
            # (bottom just past), the area's left and right, the generation and the clear colour's
            # planes. What the chip keeps for itself: where the first tile's column starts in a row
            # (the run for the place across, and the columns before the first tile painted), the
            # first and last tiles' masks, the row a band starts on and the row past its end, where
            # its first row starts in the picture, its first tile's number, the row being painted,
            # where it starts in the picture, and where the first tile's row is in the picture.
            OFFSETS = %i[rows rows_bank across run y first_x first_tile last_tile top bottom
                         area_left area_right generation clear0 clear1 clear2 clear3
                         first_column left_mask right_mask band_top band_end row_start tile_row
                         row row_at].each_with_index.to_h { |what, i| [what, i * 2] }.freeze
            BYTES = OFFSETS.length * 2
            raise "the chip's blit block is #{BYTES} bytes, over #{ChipPaint::BLIT_BYTES}" if BYTES > ChipPaint::BLIT_BYTES

            module_function

            def block_place(what) = ChipPaint::BLIT - ChipPaint::COPY + OFFSETS.fetch(what)
            def block_address(what) = ChipPaint::BLIT + OFFSETS.fetch(what)

            # --- the console's side ---

            # The rest of rt_paint_blit, from the tiles across on (Paint#emit_blit): the block
            # handed over from Paint's scratch +s+, the chip run, and what it changed of work RAM's
            # copy of the painted screen brought up to date.
            def emit_console(asm, memory, s)
              r = Paint::R
              [[:rows, s.pointer], [:rows_bank, s.pointer + 2], [:across, s.across], [:run, s.run], [:y, r.call(2)],
               [:first_x, s.first_x], [:first_tile, s.chunk], [:last_tile, s.last], [:top, s.top], [:bottom, s.bottom],
               [:area_left, s.area_left], [:area_right, s.area_right]].each do |what, from|
                asm.lda(asm.direct(from))
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
              ChipFill.emit_dirty_rows_update(asm, memory, s, "rt_paint_blit")
              ChipFill.emit_readied_map_cells(asm, memory, s, "rt_paint_blit")
              asm.rtl
            end

            # --- the chip's side ---

            # Registers of the band's code: sixteen (SIXTEEN), the tile across (COLUMN), the tile's
            # number (TILE), where a pair of planes is written (AT), the column's mask (MASK) and its
            # opposite (KEPT), the start of the tile's row in the picture (TILE_AT), and 64, from a
            # tile to the next (TILE_STEP). ChipFill#emit_tile_ready_if_old uses R0, R1, AT, HELD,
            # PAIRS, R12 and R13 besides TILE. R14 is where the cartridge is read.
            AT = ChipFill::AT
            TILE = ChipFill::TILE
            SIXTEEN = 4
            MASK = 6
            KEPT = 7
            COLUMN = 9
            TILE_AT = 8
            TILE_STEP = 10

            def section
              gsu = GSU.new("chip blit")
              gsu.label(ENTRY)
              gsu.cache
              ChipFill.emit_jump(gsu, SETUP)
              emit_band(gsu)
              ChipFill.emit_mask_of(gsu, MASK_OF, left: block_place(:area_left), right: block_place(:area_right))
              emit_setup(gsu)
              gsu.section
            end

            # One band: where it ends and starts in the picture, its tiles made ready, its rows.
            def emit_band(gsu)
              gsu.label(BAND)
              gsu.lm(0, block_place(:band_top))
              gsu.iwt(1, 0xFFF8)
              gsu.from(0).to(2).and_(1)
              gsu.with(2).add(gsu.imm(8))
              gsu.lm(3, block_place(:bottom))
              gsu.from(2).cmp(3)
              gsu.bcc("chip blit band end")
              gsu.nop
              gsu.move(2, 3)
              gsu.label("chip blit band end")
              gsu.sm(block_place(:band_end), 2)
              gsu.from(0).to(3).and_(1)
              gsu.from(3).to(4).swap
              gsu.from(0).to(5).and_(gsu.imm(7))
              gsu.with(4).add(5)
              gsu.with(4).add(5)
              gsu.sm(block_place(:row_at), 4)
              gsu.with(3).add(3)
              gsu.with(3).add(3)
              gsu.sm(block_place(:tile_row), 3)
              gsu.sm(block_place(:row), 0)
              emit_band_ready(gsu)
              emit_row(gsu)
              gsu.lm(0, block_place(:band_end))
              gsu.sm(block_place(:band_top), 0)
              gsu.lm(1, block_place(:bottom))
              gsu.cmp(1)
              gsu.bcs("chip blit done")
              gsu.nop
              ChipFill.emit_jump(gsu, BAND)
              gsu.label("chip blit done")
              gsu.stop
            end

            # Each tile of the band across made ready.
            def emit_band_ready(gsu)
              gsu.lm(COLUMN, block_place(:first_tile))
              gsu.label("chip blit ready next")
              gsu.lm(TILE, block_place(:tile_row))
              gsu.with(TILE).add(COLUMN)
              ChipFill.emit_tile_ready_if_old(gsu, "chip blit", generation: block_place(:generation), clear: block_place(:clear0))
              gsu.inc(COLUMN)
              gsu.lm(0, block_place(:last_tile))
              gsu.from(0).cmp(COLUMN)
              gsu.bcc("chip blit all ready")
              gsu.nop
              ChipFill.emit_jump(gsu, "chip blit ready next")
              gsu.label("chip blit all ready")
            end

            # Each row of the band: where the picture's row is (its table's entry, four bytes a row
            # from the picture's top), then its columns from the first tile's into the tiles' rows.
            #
            # R14 is only the address inside a bank, and nothing here carries into the bank: every
            # read stays in the bank it started in. That holds because the Linker places a section
            # whole in one bank, a picture's table of rows is in one section (Lowering::Paint's
            # "paint tables"), and Lowering::Paint#picture_row_sections starts a new section rather
            # than split a row, so each row, every run of it, is in one bank too. Paint's own
            # rt_paint_blit relies on the same.
            def emit_row(gsu)
              gsu.label("chip blit row")
              gsu.lm(0, block_place(:rows_bank))
              gsu.romb
              gsu.lm(0, block_place(:row))
              gsu.lm(1, block_place(:y))
              gsu.sub(1)
              gsu.add(0)
              gsu.add(0)
              gsu.lm(1, block_place(:rows))
              gsu.from(0).to(14).add(1)
              emit_word_read(gsu)
              gsu.move(TILE_AT, 0)
              gsu.getb
              gsu.romb
              gsu.lm(0, block_place(:first_column))
              gsu.from(TILE_AT).to(14).add(0)
              # The first tile's row in the picture.
              gsu.lm(TILE_AT, block_place(:first_tile))
              6.times { gsu.with(TILE_AT).add(TILE_AT) }
              gsu.lm(0, block_place(:row_at))
              gsu.with(TILE_AT).add(0)
              gsu.ibt(SIXTEEN, 16)
              gsu.iwt(TILE_STEP, 64)
              gsu.lm(COLUMN, block_place(:first_tile))
              emit_column(gsu)
              # The next row, unless that was the band's last.
              gsu.lm(0, block_place(:row_at))
              gsu.add(gsu.imm(2))
              gsu.sm(block_place(:row_at), 0)
              gsu.lm(0, block_place(:row))
              gsu.inc(0)
              gsu.sm(block_place(:row), 0)
              gsu.lm(1, block_place(:band_end))
              gsu.cmp(1)
              gsu.bcs("chip blit rows done")
              gsu.nop
              ChipFill.emit_jump(gsu, "chip blit row")
              gsu.label("chip blit rows done")
            end

            # R0 = the word in the cartridge at R14, R14 left past it.
            def emit_word_read(gsu)
              gsu.getb
              gsu.inc(14)
              gsu.getbh
              gsu.inc(14)
            end

            # Tile COLUMN's column of the row at R14, and the tiles after it to the last: its mask,
            # held to the area at the first and last tile, then each pair of planes held to the mask
            # into the tile's row, the tile's pixels outside the mask kept.
            def emit_column(gsu)
              gsu.label("chip blit column")
              emit_word_read(gsu)
              gsu.move(MASK, 0)
              [[:first_tile, :left_mask], [:last_tile, :right_mask]].each do |tile, mask|
                gsu.lm(0, block_place(tile))
                gsu.from(COLUMN).cmp(0)
                gsu.bne("chip blit not #{tile}")
                gsu.nop
                gsu.lm(1, block_place(mask))
                gsu.with(MASK).and_(1)
                gsu.label("chip blit not #{tile}")
              end
              gsu.moves(MASK, MASK)
              gsu.bne("chip blit drawn")
              gsu.nop
              gsu.with(14).add(gsu.imm(8)) # nothing of this tile drawn: past its planes
              gsu.bra("chip blit column done")
              gsu.nop
              gsu.label("chip blit drawn")
              gsu.from(MASK).to(KEPT).not_
              gsu.move(AT, TILE_AT)
              4.times do
                emit_word_read(gsu)
                gsu.from(0).to(1).and_(MASK)
                gsu.ldw(AT)
                gsu.and_(KEPT)
                gsu.or_(1)
                gsu.stw(AT)
                gsu.with(AT).add(SIXTEEN)
              end
              gsu.label("chip blit column done")
              gsu.with(TILE_AT).add(TILE_STEP)
              gsu.inc(COLUMN)
              gsu.lm(0, block_place(:last_tile))
              gsu.from(0).cmp(COLUMN)
              gsu.bcc("chip blit columns done")
              gsu.nop
              ChipFill.emit_jump(gsu, "chip blit column")
              gsu.label("chip blit columns done")
            end

            # Once a picture: where the first tile's column starts in a row, the first and last
            # tiles' masks held to the area, nothing readied yet, and the first band.
            def emit_setup(gsu)
              gsu.label(SETUP)
              gsu.ibt(0, 0)
              gsu.sm(ChipFill::READIED_COUNT, 0)
              # Where the run for the place across starts in a row, which the console looked up...
              gsu.lm(2, block_place(:run))
              # ...and ten bytes for each tile between the picture's first and the first painted.
              gsu.lm(0, block_place(:first_tile))
              gsu.lm(1, block_place(:first_x))
              gsu.sub(1)
              gsu.from(0).to(1).add(0)
              gsu.from(1).to(0).add(1)
              gsu.add(0)
              gsu.add(1)
              gsu.add(2)
              gsu.sm(block_place(:first_column), 0)
              [%i[first_tile left_mask], %i[last_tile right_mask]].each do |tile, mask|
                gsu.lm(3, block_place(tile))
                3.times { gsu.with(3).add(3) }
                ChipFill.emit_call(gsu, MASK_OF)
                gsu.sm(block_place(mask), 0)
              end
              gsu.lm(0, block_place(:top))
              gsu.sm(block_place(:band_top), 0)
              ChipFill.emit_jump(gsu, BAND)
            end
          end
        end
      end
    end
  end
end
