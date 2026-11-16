# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# WHAT A READER OF A RUNNING COLOR CARTRIDGE READS IS WHAT MEMORY HOLDS, whatever the console is
# doing as the frame ends. While the console copies a sprite table (OAM DMA) the processor reading
# work memory gets 0xFF, as the copy has the bus; a reader is not the processor, and a variable read
# then must not read -1. The cartridge here does nothing else: with the screen off it writes 0x5A
# at HOLDS, then copies the sprite table from work memory again and again, so most frames end
# during a copy.
class TestReadingMemoryOnTheColor < Minitest::Test
  HOLDS = 0xC100
  FRAMES = 12

  # The copy, run from quick memory as it must be: start it from 0xC000, wait the 160 cycles it
  # takes, return.
  DMA_ROUTINE = [0x3E, 0xC0, 0xE0, 0x46, 0x3E, 0x28, 0x3D, 0x20, 0xFD, 0xC9].freeze

  # The program at 0x150: interrupts off, the screen off in its blank, 0x5A at HOLDS, the copy put
  # into quick memory, then the copy called for ever.
  private def program
    [0xF3,
     0xF0, 0x44, 0xFE, 0x90, 0x38, 0xFA, # wait for line 144
     0xAF, 0xE0, 0x40,                   # the screen off
     0x3E, 0x5A, 0xEA, HOLDS & 0xFF, HOLDS >> 8,
     0x21, 0x80, 0xFF,
     *DMA_ROUTINE.flat_map { |byte| [0x36, byte, 0x23] },
     0xCD, 0x80, 0xFF, 0x18, 0xFB] # call the copy, and again
  end

  private def cartridge_bytes
    rom = Array.new(0x8000, 0)
    rom[0x100, 4] = [0x00, 0xC3, 0x50, 0x01] # nop; jp 0x150
    logo = VBlank::Cartridge::GBCROM::LOGO
    rom[VBlank::Cartridge::GBCROM::LOGO_AT, logo.size] = logo
    "COPYING".bytes.each_with_index { |byte, at| rom[0x134 + at] = byte }
    rom[0x143] = 0xC0 # for the Color only
    rom[0x14D] = (0x134..0x14C).reduce(0) { |sum, at| (sum - rom[at] - 1) & 0xFF }
    rom[0x150, program.length] = program
    rom.pack("C*")
  end

  def test_a_byte_reads_as_written_while_the_sprite_table_is_copied
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "copying.gbc")
      File.binwrite(path, cartridge_bytes)
      read = VBlank::Playthroughs::Probe.open(path) do |probe|
        Array.new(FRAMES) do
          probe.step
          probe.read(HOLDS)
        end
      end

      assert_equal [0x5A] * FRAMES, read
    end
  end
end
