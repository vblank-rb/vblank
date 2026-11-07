# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # THE SEGA GENESIS'S PACKED FORMATS, which the copy of a Genesis original offers: the formats
      # Sega's own games and many others keep their tiles and plane maps in, read as the 68000
      # routines retail games run read them (`NemDec` and `EniDec`, as Dr. Robotnik's Mean Bean
      # Machine has them), which are their answer key. A block has no header of the BIOS's kind:
      # Nemesis says its tile count, and Enigma ends with a mark of its own.
      #
      #   copy.unpack_nemesis at: 0x4000, into: pack[:tiles]
      #   copy.unpack_enigma at: 0x5000, into: pack[:map], base: 0x2000
      #
      # Both read the copy as a stream of bits, the top bit of each byte first (Bits). Written with
      # Format and the BlockKit alone, as a port writes a format of its own. Read as game code
      # (VBlank.require_game_file).
      module Genesis
        # THE COPY AS A STREAM OF BITS, read a byte at a time from the variable :src as bits are
        # needed: at least +need+ (16 at most) not yet taken are kept at the bottom of the variable
        # :bits, and :have says how many. What is above them in :bits is never read, so it may slide
        # off the top.
        module Bits
          def self.emit_empty(block)
            block.variable(:bits).store!(0)
            block.variable(:have).store!(0)
          end

          def self.emit_kept(block, need)
            bits = block.variable(:bits)
            have = block.variable(:have)
            src = block.variable(:src)
            block.repeat(3, stop_when: have >= need) do
              bits.store!((bits << 8) | block.byte(src))
              src.increase!(1)
              have.increase!(8)
            end
          end

          # The next +count+ bits kept, not taken.
          def self.peek(block, count)
            mask = count.is_a?(Integer) ? (1 << count) - 1 : (block.value_of(1) << count) - 1
            (block.variable(:bits) >> (block.variable(:have) - count)) & mask
          end

          def self.take(block, count)
            have = block.variable(:have)
            have.store!(have - count)
          end
        end

        # NEMESIS, for tiles. Two bytes high byte first: the top bit is XOR mode, and the low 13 the
        # tile count (the original counts rows in 16 bits, so a count past 8191 would wrap; 0 tiles
        # writes nothing here, where the original would run on). Then the table of codes
        # (#emit_codes), then the codes, each a run of 1 to 8 pixels of one colour, filling each row
        # of a tile from the left, four bits a pixel. A code is found by the next 8 bits; 0xFC and up
        # is 111111 and then 7 bits spelt out: the run less one and the colour. Each row of 8 pixels
        # is a word, written high byte first as the Genesis keeps it; in XOR mode the word is how the
        # row differs from the row before.
        #
        # A code is looked up by 8 bits, so the last one may read a byte after the block, as the
        # original does; a block that ends on the copy's last byte can read past the copy.
        module Nemesis
          extend Format
          unpacks :nemesis
          called "Nemesis"

          # How many bytes a tile unpacks to, and how many places the table of codes has.
          TILE_BYTES = 32
          LOOKUPS = 256

          def self.routine(block)
            from = block.from
            header = block.variable(:header)
            entry = block.variable(:entry)
            row = block.variable(:row)
            pixels = block.variable(:pixels)
            previous = block.variable(:previous)
            header.store!((block.byte(from) << 8) | block.byte(from + 1))
            block.expect_size((header & 0x1FFF) * TILE_BYTES)
            block.variable(:src).store!(from + 2)
            codes = block.list(:nemesis_codes, capacity: LOOKUPS, width: :half)
            emit_codes(block, codes)
            Bits.emit_empty(block)
            row.store!(0)
            pixels.store!(0)
            previous.store!(0)
            # Each pass writes a pixel at least, two to a byte.
            block.repeat((header & 0x1FFF) * TILE_BYTES * 2, stop_when: block.finished) do
              Bits.emit_kept(block, 8)
              entry.store!(Bits.peek(block, 8))
              if entry >= 0xFC
                Bits.take(block, 6)
                Bits.emit_kept(block, 7)
                entry.store!(Bits.peek(block, 7))
                Bits.take(block, 7)
              else
                entry.store!(codes[entry])
                Bits.take(block, entry >> 8)
              end
              block.repeat(((entry >> 4) & 7) + 1, stop_when: block.finished) do
                row.store!((row << 4) | (entry & 0xF))
                pixels.increase!(1)
                if pixels == 8
                  if (header & 0x8000) == 0
                    previous.store!(row)
                  else
                    previous.store!(previous ^ row)
                  end
                  block.write(previous >> 24)
                  block.write(previous >> 16)
                  block.write(previous >> 8)
                  block.write(previous)
                  row.store!(0)
                  pixels.store!(0)
                end
              end
            end
          end

          # The table of codes, read from :src into +codes+, a list with a place for each 8 bits a
          # code can start with. A byte with its top bit set is a colour (the first byte is one
          # whatever it is, as in the original), and 0xFF ends the table. Each byte after a colour
          # below 0x80 is a code: bits 4 to 6 its run less one, bits 0 to 3 its length in bits, and
          # the next byte the code itself. It is put in every place whose top bits it is. Each place
          # keeps the length in bits 8 to 11, the run in 4 to 6 and the colour in 0 to 3. A code of
          # more than 8 bits is left out, as no real table has one. The list is all 0 for each block,
          # so a place no code names reads as a run of one pixel of colour 0, where the original
          # reads whatever an earlier table left there.
          def self.emit_codes(block, codes)
            src = block.variable(:src)
            colour = block.variable(:colour)
            byte = block.variable(:table_byte)
            spread = block.variable(:spread)
            lookup = block.variable(:lookup)
            ended = block.variable(:table_ended)
            ended.store!(0)
            colour.store!(block.byte(src))
            src.increase!(1)
            ended.store!(1) if colour == 0xFF
            # Each pass reads a byte at least, and a table has a place for each 8 bits twice over.
            block.repeat(LOOKUPS * 4, stop_when: ended == 1) do
              byte.store!(block.byte(src))
              src.increase!(1)
              if byte >= 0x80
                if byte == 0xFF
                  ended.store!(1)
                else
                  colour.store!(byte)
                end
              else
                spread.store!(8 - (byte & 0xF))
                lookup.store!(block.byte(src) << spread)
                src.increase!(1)
                if spread >= 0
                  block.repeat(block.value_of(1) << spread) do |i|
                    codes[lookup + i] = (colour & 0xF) | (byte & 0x70) | ((byte & 0xF) << 8) if lookup + i < LOOKUPS
                  end
                end
              end
            end
          end
        end

        # ENIGMA, for plane maps. A map is cells, a word each, written high byte first as the Genesis
        # keeps a word, each with the setting base: added. Six bytes of header: the width in bits of
        # a cell spelt out; which flips a spelt cell carries a bit for (bit 1 top to bottom, 0x1000,
        # read first; bit 0 side to side, 0x800); the counting word and the repeating word, high byte
        # first. Then ops, each a code and a count less one in 4 bits:
        #
        #   00   the counting word, which goes up by one for each cell it writes
        #   01   the repeating word
        #   100  one cell spelt out, for each cell
        #   101  one cell spelt out, going up by one for each cell
        #   110  one cell spelt out, going down by one for each cell
        #   111  a cell spelt out for each cell; with a count of 15, the end of the map
        #
        # NOT THE USUAL READING: the format's usual reading lets a spelt cell carry palette and
        # priority bits too, and this routine, as Mean Bean Machine's `EniDec`, reads only the two
        # flips. A flip is OR'd into the base, and the cell's bits are added to that.
        #
        # The size is not known until the end mark, so each byte is checked against the slot as it
        # is written, and the first that does not fit is a fault and ends the map.
        module Enigma
          extend Format
          unpacks :enigma, base: 0
          called "Enigma"

          def self.routine(block)
            from = block.from
            base = block.setting(:base)
            counting = block.variable(:counting)
            repeating = block.variable(:repeating)
            op = block.variable(:op)
            many = block.variable(:many)
            cell = block.variable(:cell)
            step = block.variable(:step)
            block.variable(:width).store!(block.byte(from))
            block.variable(:flips).store!(block.byte(from + 1))
            counting.store!(((block.byte(from + 2) << 8) | block.byte(from + 3)) + base)
            repeating.store!(((block.byte(from + 4) << 8) | block.byte(from + 5)) + base)
            block.variable(:src).store!(from + 6)
            Bits.emit_empty(block)
            # Each op but the end writes a cell, or fails to and ends the map.
            block.repeat(block.room + 2, stop_when: block.finished) do
              Bits.emit_kept(block, 7)
              op.store!(Bits.peek(block, 7))
              if op < 0x40
                many.store!(((op >> 1) & 0xF) + 1)
                Bits.take(block, 6)
              else
                many.store!((op & 0xF) + 1)
                Bits.take(block, 7)
              end
              op.store!(op >> 4)
              if op < 2
                block.repeat(many, stop_when: block.finished) do
                  emit_cell(block, counting)
                  counting.increase!(1)
                end
              elsif op < 4
                block.repeat(many, stop_when: block.finished) { emit_cell(block, repeating) }
              elsif op == 7
                if many == 16
                  block.finish!
                else
                  block.repeat(many, stop_when: block.finished) do
                    emit_spelt(block, cell)
                    emit_cell(block, cell)
                  end
                end
              else
                step.store!(0)
                step.store!(1) if op == 5
                step.store!(-1) if op == 6
                emit_spelt(block, cell)
                block.repeat(many, stop_when: block.finished) do
                  emit_cell(block, cell)
                  cell.store!(cell + step)
                end
              end
            end
          end

          # One cell of the map, high byte first.
          def self.emit_cell(block, value)
            block.write(value >> 8)
            block.write(value)
          end

          # A cell spelt out in the map, into +cell+: a bit for each flip the header names, then the
          # cell's bits, added to the base with those flips.
          def self.emit_spelt(block, cell)
            flips = block.variable(:flips)
            width = block.variable(:width)
            cell.store!(block.setting(:base))
            [[2, 0x1000], [1, 0x800]].each do |named, flip|
              if (flips & named) != 0
                Bits.emit_kept(block, 1)
                cell.store!(cell | flip) if Bits.peek(block, 1) == 1
                Bits.take(block, 1)
              end
            end
            Bits.emit_kept(block, width)
            cell.store!(Bits.peek(block, width) + cell)
            Bits.take(block, width)
          end
        end

        FORMATS = [Nemesis, Enigma].freeze
      end
    end
  end
end
