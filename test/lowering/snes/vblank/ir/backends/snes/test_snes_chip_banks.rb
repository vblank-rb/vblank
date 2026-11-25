# frozen_string_literal: true

require "test_helper"
require "stringio"

# Chip code in two banks of a Super FX cartridge. The chip reads its program from the bank its
# program bank register (PBR, $3034) names, and writing that register empties its 512-byte
# instruction cache (fullsnes, "SNES Cart GSU-n Code-Cache"; bsnes's SuperFX::writeIO does the
# same). So Runtime::Chip's rt_chip_run sets the bank only when it is not the one already there:
# the chip's rectangles run one after another from the cache, while a game's own chip routine in
# another bank still gets its bank set.
#
# Here the game's chip code is big enough that the linker puts it in a bank of its own, away from
# the chip's rectangles and pictures: one long routine run once at the start, and a short one run
# twice a pass, both in the one section ChipCode makes. A pass runs the programs in turns:
# rectangles, the short routine, a rectangle and a picture placed by what it worked out, the
# routine again, rectangles again.
class TestSNESChipBanks < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  BALL = ["..####..", ".######.", "########", "########", "########", "########", ".######.", "..####.."].join("\n")
  # Rounds of the long routine written out, more code than the first bank has room left for.
  ROUNDS = 250
  MULTIPLIERS = [75, 77, 81, 83, 89].freeze
  COLORS = %i[red yellow blue white magenta orange].freeze
  ROW = (0...10).to_a.freeze

  def self.two_banks
    VBlank.game("CHIP TWO BANKS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image(:ball, "." => :transparent, "#" => :yellow) { TestSNESChipBanks::BALL }
      a = var :a, 1
      b = var :b, 2
      n = var :n, 0

      func :scramble, on_chip: true do
        TestSNESChipBanks::ROUNDS.times do |k|
          a = ((a * TestSNESChipBanks::MULTIPLIERS[k % 5]) + 74) & 0xFFFF
          b = b ^ (a >> 3)
        end
      end

      func :step, on_chip: true do
        a = ((a * 75) + 74) & 0xFFFF
        b = b ^ (a >> 3)
      end

      call :scramble
      game_loop do
        clear_screen :black
        TestSNESChipBanks::ROW.each { |i| draw_rect_at (i * 20) + (n & 7), 8, 6, 6, TestSNESChipBanks::COLORS[i % 6] }
        call :step
        draw_rect_at a & 127, 40, 16, 16, :green
        blit :ball, b & 127, 70
        call :step
        TestSNESChipBanks::ROW.each { |i| draw_rect_at (i * 20) + (a & 7), 100, 6, 6, TestSNESChipBanks::COLORS[i % 6] }
        n += 1
      end
    end
  end

  private def superfx_rom
    self.class.two_banks.build_rom(console: :snes, variant: :superfx, out: StringIO.new, err: StringIO.new, profile: false)
  end

  private def bank_of(code, label) = code.fetch(label) >> 16

  # Without this the test would pass with the bank check gone: every chip program in one bank.
  def test_the_routine_sits_in_another_bank_than_the_rectangles_and_pictures
    code = superfx_rom.built.code
    routine = bank_of(code, SNES::ChipCode.entry_label(:step))

    refute_equal bank_of(code, SNES::Runtime::ChipFill::ENTRY), routine
    refute_equal bank_of(code, SNES::Runtime::ChipBlit::ENTRY), routine
  end

  # Each pass runs the rectangles' program, the routine, the pictures' program and the routine
  # again: a bank left set from the run before runs the wrong bank's code, and the picture or the
  # numbers part from the interpreter's, or the chip never stops and the pass never ends.
  def test_chip_code_in_two_banks_plays_as_on_the_interpreter
    run = game_player.run(self.class.two_banks.program(console: :snes, variant: :superfx), frames: 30)

    refute_equal 1, run[:a], "the routines in the other bank ran"
    refute_equal run.screen.pixel(239, 159), run.screen.pixel(((run[:n] - 1) & 7) + 2, 10),
                 "the first bank's rectangles are drawn"
  end

  # Ten rectangles in a row reuse the code the first of them left in the chip's cache. Setting the
  # bank before every run, the same bank or not, empties the cache each time, so every rectangle
  # loads its code again from the ROM at five cycles a byte. The bar sits between the share of the
  # frame left over with the bank set only when it changes and with it set on every run.
  def test_rectangles_in_a_row_keep_the_chips_cache
    assert_operator superfx_rom.profile(out: StringIO.new, settle: 10, frames: 20).idle_share, :>=, 0.235
  end
end
