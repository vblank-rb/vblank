# frozen_string_literal: true

require "test_helper"

class TestTurnedBackgroundRow < Minitest::Test
  # Every console refuses a turned background held above a row today, so only the interpreter is asked.
  def test_a_turned_background_held_above_a_row_keeps_to_its_rows
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :black
      image :field, width: 8, height: 8, data: Array.new(64, :red)
      tiles :set, "#" => :field
      bar = background :bar, tiles: :set, map: Array.new(32) { "#" * 32 }, above_row: 32
      game_loop do
        bar.rotate!(0)
        wait_vblank
      end
    end
    b.finalize_program
    i = VBlank::IR::Backends::Reference.new.run(b.program, frames: 3)

    assert_equal 0x001F, i.screen.pixel(10, 10)
    assert_equal 0, i.screen.pixel(10, 100)
  end
end
