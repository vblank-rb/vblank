# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # THE GAME BOY ADVANCE'S PACKED FORMATS, which the copy of an Advance original offers: the
      # formats of the console's BIOS, the ones retail cartridges keep their pictures in and the ones
      # the GBA lowering packs with (BiosCompress, which is their answer key). A packed block starts
      # with four bytes: the scheme in the top half of the first and the size unpacked in the next
      # three, low byte first.
      #
      #   copy.unpack_lz77 at: 0x300, into: pack[:sprites]
      #   copy.unpack_rle at: 0x380, into: pack[:heights], start: 16
      #
      # Written with Format and the BlockKit alone, as a port writes a format of its own. Read as
      # game code (VBlank.require_game_file).
      module GBA
        Packer = IR::Backends::GBA::BiosCompress

        # The four bytes every BIOS block starts with: the scheme checked, then the size expected,
        # then the block, handed its size and where its packed bytes start. A block of another scheme
        # is the fault the build stops on.
        def self.emit_bios_block(block, scheme)
          from = block.from
          size = block.variable(:size)
          src = block.variable(:src)
          if (block.byte(from) >> 4) == scheme
            size.store!(block.byte(from + 1) | (block.byte(from + 2) << 8) | (block.byte(from + 3) << 16))
            block.expect_size(size)
            src.store!(from + 4)
            yield size, src
          else
            block.emit_wrong_format_fault
          end
        end

        # LZ77 is groups of a flag byte and eight items, the flag's top bit first: a 0 is one byte to
        # copy, a 1 is two bytes saying "the 3 to 18 bytes from 1 to 4096 back again".
        module LZ77
          extend Format
          unpacks :lz77
          called Packer::SCHEME_NAMES.fetch(:lz77)

          def self.routine(block)
            flags = block.variable(:flags)
            reference = block.variable(:reference)
            back = block.variable(:back)
            GBA.emit_bios_block(block, Packer::TYPE_LZ77) do |size, src|
              block.repeat(size, stop_when: block.finished) do
                flags.store!(block.byte(src))
                src.increase!(1)
                block.repeat(8, stop_when: block.finished) do
                  if (flags & 0x80) == 0
                    block.write(block.byte(src))
                    src.increase!(1)
                  else
                    reference.store!(block.byte(src))
                    back.store!((((reference & 0x0F) << 8) | block.byte(src + 1)) + 1)
                    src.increase!(2)
                    block.repeat((reference >> 4) + 3, stop_when: block.finished) { block.write(block.written_byte(back)) }
                  end
                  flags.store!(flags << 1)
                end
              end
            end
          end
        end

        # RLE is runs: a flag byte with its top bit set is one byte written 3 to 130 times, and with
        # it clear 1 to 128 bytes to copy.
        module RLE
          extend Format
          unpacks :rle
          called Packer::SCHEME_NAMES.fetch(:rle)

          def self.routine(block)
            flag = block.variable(:flag)
            fill = block.variable(:fill)
            GBA.emit_bios_block(block, Packer::TYPE_RLE) do |size, src|
              block.repeat(size, stop_when: block.finished) do
                flag.store!(block.byte(src))
                src.increase!(1)
                if (flag & 0x80) == 0
                  block.repeat((flag & 0x7F) + 1, stop_when: block.finished) do
                    block.write(block.byte(src))
                    src.increase!(1)
                  end
                else
                  fill.store!(block.byte(src))
                  src.increase!(1)
                  block.repeat((flag & 0x7F) + 3, stop_when: block.finished) { block.write(fill) }
                end
              end
            end
          end
        end

        FORMATS = [LZ77, RLE].freeze
      end
    end
  end
end
