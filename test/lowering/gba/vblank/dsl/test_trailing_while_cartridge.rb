# frozen_string_literal: true

require "test_helper"
require "stringio"

# A `while` written after its body goes round on the cartridge as the block form does: the wait
# on the scanline ends past the line the game waits for, and a counted trailing loop counts.
class TestTrailingWhileCartridge < Minitest::Test
  def test_a_trailing_wait_on_the_scanline_ends_at_the_late_line
    rom = VBlank.build("TRAILWAIT", console: :gba, err: StringIO.new, out: StringIO.new) do
      extend VBlank::Builder::Debug
      screen :bitmap
      late_line = var :late_line, 100
      line = var :line, 0
      game_loop do
        line = 0
        line = read_scanline while line < late_line
      end
    end
    assert_operator assert_emulator_loads_rom(rom, frames: 4).var(:line), :>=, 100
  end

  def test_a_trailing_count_reaches_its_limit
    rom = VBlank.build("TRAILCOUNT", console: :gba, err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      limit = var :limit, 7
      i = var :i, 0
      total = var :total, 0
      game_loop do
        i = 0
        total = 0
        total += i while (i += 1) < limit
      end
    end
    player = assert_emulator_loads_rom(rom, frames: 4)
    assert_equal [7, 21], [player.var(:i), player.var(:total)]
  end
end
