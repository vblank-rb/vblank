# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# What clearing the screen costs a game of big pixels (`screen :bitmap, pixel_size: 2`), measured in
# the emulator over the frame it clears on. The display shows only the left 120 columns of the top 80
# rows of the painted screen's memory, so a clear that writes 240 columns of them writes half of
# what is never seen. Filled a row at a time, 120 columns each, it costs the engine's start for each
# row and half the words. The budgets sit a little over what that costs on the cartridge today and
# well under what filling whole rows cost (a frame is 280,896 cycles; GBATEK, "LCD Timings").
class TestBiggerPixelsClearCost < Minitest::Test
  include EmulatorSupport

  def setup
    require_emulator!
  end

  DIRECT_BUDGET = 17_000
  TEAR_FREE_BUDGET = 9_500

  # The cycles of a frame that clears the screen, less the same frame of a game that waits.
  private def clear_cycles(tear_free:, clears:)
    game = VBlank.game("CLEARCOST", consoles: %i[gba]) do
      screen :bitmap, tear_free: tear_free, pixel_size: 2
      game_loop do
        clear_screen :red if clears
        wait_vblank unless clears
      end
    end
    rom = game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "clear.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        cost = probe.frame_cost(settle: 10, keys: nil)
        [cost.busy_cycles, cost.active_cycles].max
      ensure
        probe.close
      end
    end
  end

  def test_a_direct_colour_clear_of_big_pixels_costs_under_the_budget
    spent = clear_cycles(tear_free: false, clears: true) - clear_cycles(tear_free: false, clears: false)

    assert_operator spent, :<, DIRECT_BUDGET, "the clear cost #{spent} cycles"
  end

  def test_a_tear_free_clear_of_big_pixels_costs_under_the_budget
    spent = clear_cycles(tear_free: true, clears: true) - clear_cycles(tear_free: true, clears: false)

    assert_operator spent, :<, TEAR_FREE_BUDGET, "the clear cost #{spent} cycles"
  end
end
