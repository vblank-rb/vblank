# frozen_string_literal: true

require "test_helper"

# A light in a game written in normal Ruby. Only the Advance has a light, so this is played only
# as the Advance, where TestPlainRuby is played as every console.
class TestSpotlightPlainRubyOnTheAdvance < Minitest::Test
  def test_a_light_moved_to_two_variables_takes_their_numbers
    builder = Builder.new
    game = VBlank::DSL::PlainRuby.rewrite(proc do
      screen :tiled
      # Something for the screen to show, or every build refuses the game as a black screen.
      image(:floor, "#" => :orange) { "########\n" * 8 }
      tiles :ground, "#" => :floor
      background :level, tiles: :ground, map: "#"
      light = spotlight at: [0, 0], radius: 8, dark: 50
      x = 30
      y = 40
      seen_x = 0
      seen_y = 0
      game_loop do
        light.move_to x, y
        seen_x = light.x
        seen_y = light.y
        x += 0
        y += 0
      end
    end)
    builder.instance_eval(&game)
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [30, 40], [player[:seen_x], player[:seen_y]]
  end
end
