# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # THE GAME BOY ADVANCE'S PACKED FORMATS, as building blocks of an unpacking routine
      # (CopyReader, which this is mixed into): the formats of the console's BIOS, the ones retail
      # cartridges keep their pictures in and the ones the GBA lowering packs with (BiosCompress,
      # which is their answer key). A packed block starts with four bytes: the scheme in the top half
      # of the first (Unpacking::SCHEME_NAMES) and the size unpacked in the next three, low byte first.
      #
      #   copy.unpack_lz77 at: 0x300, into: pack[:sprites]
      #   copy.unpack_rle at: 0x380, into: pack[:heights], start: 16
      #
      # - LZ77 is groups of a flag byte and eight items, the flag's top bit first: a 0 is one byte to
      #   copy, a 1 is two bytes saying "the 3 to 18 bytes from 1 to 4096 back again".
      # - RLE is runs: a flag byte with its top bit set is one byte written 3 to 130 times, and with
      #   it clear 1 to 128 bytes to copy.
      #
      # Read as game code (VBlank.require_game_file), as CopyReader is.
      module GBA
        # The block packed with the BIOS's LZ77 at +at+ in the copy, unpacked into +into+ from its
        # byte +start+.
        def unpack_lz77(at:, into:, start: 0) = unpack_packed_block(:lz77, at, into, start)

        # The block packed with the BIOS's RLE at +at+ in the copy, unpacked into +into+ from its
        # byte +start+.
        def unpack_rle(at:, into:, start: 0) = unpack_packed_block(:rle, at, into, start)

        private

        # What the two schemes share: the header checked, then the block (CopyReader#emit_sized_block).
        def emit_bios_block(scheme, &unpack)
          from = block_variable(:from)
          size = block_variable(:size)
          if (read_byte(from) >> 4) == scheme
            size.store!(read_byte(from + 1) | (read_byte(from + 2) << 8) | (read_byte(from + 3) << 16))
            emit_sized_block(size, from + 4, &unpack)
          else
            @faults.emit_fault(Unpacking::Fault::WRONG_SCHEME, from, scheme)
          end
        end

        def emit_lz77_routine
          flags = block_variable(:flags)
          reference = block_variable(:reference)
          back = block_variable(:back)
          pack = @pack
          emit_bios_block(IR::Backends::GBA::BiosCompress::TYPE_LZ77) do |src, out, ends, mark|
            @builder.repeat(ends - out, stop_when: out >= ends) do
              flags.store!(read_byte(src))
              src.increase!(1)
              @builder.repeat(8, stop_when: out >= ends) do
                if (flags & 0x80) == 0
                  pack[out] = read_byte(src)
                  src.increase!(1)
                  out.increase!(1)
                else
                  reference.store!(read_byte(src))
                  back.store!((((reference & 0x0F) << 8) | read_byte(src + 1)) + 1)
                  src.increase!(2)
                  @builder.repeat((reference >> 4) + 3, stop_when: out >= ends) do
                    pack[out] = pack[out - back]
                    out.increase!(1)
                  end
                end
                flags.store!(flags << 1)
              end
              emit_progress_step(out, mark)
            end
          end
        end

        def emit_rle_routine
          flag = block_variable(:flag)
          fill = block_variable(:fill)
          pack = @pack
          emit_bios_block(IR::Backends::GBA::BiosCompress::TYPE_RLE) do |src, out, ends, mark|
            @builder.repeat(ends - out, stop_when: out >= ends) do
              flag.store!(read_byte(src))
              src.increase!(1)
              if (flag & 0x80) == 0
                @builder.repeat((flag & 0x7F) + 1, stop_when: out >= ends) do
                  pack[out] = read_byte(src)
                  src.increase!(1)
                  out.increase!(1)
                end
              else
                fill.store!(read_byte(src))
                src.increase!(1)
                @builder.repeat((flag & 0x7F) + 3, stop_when: out >= ends) do
                  pack[out] = fill
                  out.increase!(1)
                end
              end
              emit_progress_step(out, mark)
            end
          end
        end
      end
    end
  end
end
