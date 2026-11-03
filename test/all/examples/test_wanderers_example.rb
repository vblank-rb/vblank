# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/wanderers").to_s

# The Wanderers example (examples/wanderers.rb) as a cartridge builds it, on every run's player:
# one seat, since each console it is for reads one controller. The first player walks the map with
# the D-pad, drawn in the colour the game picked when they joined. Four players at once are a
# computer build's, played in test/wanderers_tests.rb.
class TestWanderersExample < Minitest::Test
  # Where on a walker its own colour is sure to be, from its top left (see WanderersTests::BODY).
  BODY = [3, 3].freeze

  private def program
    skip_unless_written_for Wanderers::GAME
    Wanderers::GAME.program(console: game_console)
  end

  private def start
    width, height = VBlank::Console.described(game_console).screen_size
    Wanderers::Layout.new(width: width, height: height).starts.first
  end

  # Right for six frames, then down for four, then still for three more, so the sprite stands
  # where the last move put it on every console.
  private def right_then_down(frame)
    if frame <= 6 then [:right]
    elsif frame <= 10 then [:down]
    else []
    end
  end

  def test_the_first_player_walks_with_the_d_pad_in_the_colour_picked_for_them
    run = game_player.input_each_frame { |frame| right_then_down(frame) }.run(program, frames: 13)

    hue = run[:hue1]
    assert_includes 0...Wanderers::COLORS.size, hue, "the first player has a colour picked"
    x, y = start
    assert_equal shown(Wanderers::COLORS.fetch(hue)), run.screen.pixel(x + 6 + BODY[0], y + 4 + BODY[1])
  end
end
