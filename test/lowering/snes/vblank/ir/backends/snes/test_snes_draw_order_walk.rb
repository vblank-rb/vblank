# frozen_string_literal: true

require "test_helper"

# A DRAW ORDER WHOSE LIST SOMETHING TAKES ITEMS FROM THE FRONT OF, on the Super Nintendo: its slots
# move round, so its entries are read as the interpreter reads the list (DrawOrderWalk) rather than a
# slot an entry, through the table of placings the slot-by-slot read uses. A run of 128 sprites, as
# many as the console keeps places for, fits a bank so.
class TestSNESDrawOrderWalk < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  BLOCK = Ractor.make_shareable(Array.new(16) { "#" * 16 }.join("\n"))
  SPECK = Ractor.make_shareable((["#" * 8] * 8).join("\n"))
  OVERLAP = [70, 66].freeze

  # A crowd of 126 that never comes out, an enemy and a hero overlapping at OVERLAP, all 128 taking
  # turns in front, and the front item of their order list dropped every pass. The order is copied in
  # whole before each frame is drawn, so the list is full again, its first item one slot further on.
  private def crowded_game
    block = BLOCK
    speck = SPECK
    order = VBlank::Messages::MadeNames.make(:draw_order, number: 1, part: :order)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      image(:speck, "#" => :blue) { speck }
      crowd = pool :crowd, x: 0, y: 0, capacity: 126, image: :speck
      enemy = sprite :enemy, at: [60, 60]
      hero = sprite :hero, at: [68, 66]
      draw_in_order(crowd, enemy, hero, take_turns: true)
      game_loop { record(VBlank::IR::Build.list_drop(order, from: :front)) }
    end
    b.finalize_program
    b.program.copy.tap { |copy| copy.console = :snes }
  end

  def test_an_order_of_128_dropped_from_the_front_builds_and_plays_alike
    seen = [2, 3, 4].map { |frames| SNES::CheckedRun.new.run(crowded_game, frames: frames).screen.pixel(*OVERLAP) }

    assert_equal [Color.resolve(:green), Color.resolve(:red)].sort, seen.uniq.sort, "the two take turns in front"
  end
end
