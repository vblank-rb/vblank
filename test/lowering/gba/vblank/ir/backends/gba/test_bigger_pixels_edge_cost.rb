# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# What a picture drawn past the edge of a game of big pixels costs (`screen :bitmap, pixel_size: 2`),
# measured in the emulator over a frame. The display shows only the left 120 columns of the top 80
# rows of the painted screen's memory, so a picture is cut at that edge, as the interpreter cuts it,
# and what lies past it is never written. Before, a picture wholly past the edge cost what one in
# the middle of the screen does. The budget for one wholly past the edge is the cost of deciding to
# draw nothing, well under a picture drawn: 32x32 pixels cost about 4,400 cycles on the plain
# painted screen and 2,900 on the tear-free one.
class TestBiggerPixelsEdgeCost < Minitest::Test
  include EmulatorSupport

  def setup
    require_emulator!
  end

  PAST_THE_EDGE_BUDGET = 500

  # The cycles of a frame that draws a 32x32 picture at +at+, less the same frame of a game that
  # draws none.
  private def blit_cycles(tear_free:, at:)
    [true, false].map do |blits|
      game = VBlank.game("EDGECOST", consoles: %i[gba]) do
        screen :bitmap, tear_free: tear_free, pixel_size: 2
        image(:box, "#" => :red, "." => :blue) { Array.new(32) { |r| r.even? ? "#." * 16 : ".#" * 16 }.join("\n") }
        game_loop do
          blit :box, at[0], at[1] if blits
          wait_vblank
        end
      end
      frame_cycles(game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false))
    end.inject(:-)
  end

  private def frame_cycles(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "edge.gba")
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

  def test_a_picture_past_the_edge_of_the_plain_painted_screen_costs_nothing_to_draw
    spent = blit_cycles(tear_free: false, at: [150, 100])

    assert_operator spent, :<, PAST_THE_EDGE_BUDGET, "the picture past the edge cost #{spent} cycles"
  end

  def test_a_picture_past_the_edge_of_the_tear_free_screen_costs_nothing_to_draw
    spent = blit_cycles(tear_free: true, at: [150, 100])

    assert_operator spent, :<, PAST_THE_EDGE_BUDGET, "the picture past the edge cost #{spent} cycles"
  end
end
