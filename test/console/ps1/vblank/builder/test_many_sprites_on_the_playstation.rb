# frozen_string_literal: true

require "test_helper"

# More than 128 sprites on one screen, on every run that plays games as the PlayStation. Its graphics
# chip draws whatever it is sent, and a game can keep places for 512 sprites there
# (Console::PLAYSTATION's sprite_places), so every sprite the frame shows is drawn, as the interpreter
# draws it. Not in test/all/: the Color, the Super Nintendo and the Genesis keep places for fewer.
class TestManySpritesOnThePlayStation < Minitest::Test
  COUNT = 140

  def test_every_sprite_past_the_128th_is_drawn
    run = game_player.run(crowd_program, frames: 3)

    assert_equal COUNT, run.sprites.length, "every sprite the frame shows"
    assert_equal Color.resolve(:green), run.screen.pixel(4 + ((COUNT - 1) % 20 * 12), 4 + ((COUNT - 1) / 20 * 12)),
                 "the last sprite declared"
  end

  private def crowd_program
    count = COUNT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :green) { (["########"] * 8).join("\n") }
      count.times { |i| sprite :dot, at: [(i % 20) * 12, (i / 20) * 12] }
      game_loop {}
    end
    b.finalize_program
    b.program
  end
end
