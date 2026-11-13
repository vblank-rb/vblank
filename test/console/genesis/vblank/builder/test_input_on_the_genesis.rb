# frozen_string_literal: true

require "test_helper"

# The button only a Genesis pad has, C. What every console's buttons do is
# test/all/vblank/builder/test_input.rb; these are the same words on the one it adds. C is the last of
# IR::Buttons::NAMES, so it is the button a build loses when it keeps fewer bits of a player's
# buttons than that list has.
class TestInputOnTheGenesis < Minitest::Test
  # A white square shown while C is held, and counts of the passes C was held and the times it went
  # down.
  private def mark_while_c_game
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :genesis))
    builder.instance_eval do
      screen :tiled, backdrop: :black
      colors :mark, %i[transparent white]
      image :mark, width: 8, height: 8, colors: :mark, places: [1] * 64
      mark = sprite :mark, at: [16, 16], shown: false
      held_c = var :held_c, 0
      pressed_c = var :pressed_c, 0
      any = var :any, 0
      game_loop do
        if held(:c)
          mark.show
          held_c += 1
        else
          mark.hide
        end
        pressed_c += 1 if pressed(:c)
        any += 1 if pressed(:any)
      end
    end
    builder.finalize_program
    builder.program
  end

  private def played(frames, &buttons) = game_player.input_each_frame(&buttons).run(mark_while_c_game, frames: frames)

  def test_c_held_to_the_end_shows_the_mark
    run = played(8) { |frame| frame >= 2 ? [:c] : [] }

    assert_equal 1, run[:pressed_c]
    assert_equal VBlank::Testing.shown(:white), run.screen.pixel(16, 16), "the mark, shown while C is held"
  end

  def test_c_is_held_for_as_long_as_it_is_down_and_the_mark_hides_once_it_is_up
    run = played(8) { |frame| frame.between?(2, 3) ? [:c] : [] }

    assert_equal 2, run[:held_c]
    refute_equal VBlank::Testing.shown(:white), run.screen.pixel(16, 16), "the mark, hidden once C is let go"
  end

  # A title that waits for any button counts C as well.
  def test_c_is_any_button
    run = played(10) { |frame| [2, 6].include?(frame) ? [:c] : [] }

    assert_equal 2, run[:pressed_c]
    assert_equal 2, run[:any]
  end
end
