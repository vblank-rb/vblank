# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/everywhere").to_s

# The one-file-for-four-consoles example (examples/everywhere.rb): a ball bouncing round whatever
# screen the build is for, under a title, to a tune, with the Super Nintendo's build titled SUPER
# BOUNCE and holding no tune. Played on every lowering, on the console each run plays a game as.
class TestEverywhereExample < Minitest::Test
  YELLOW = Color.resolve(:yellow)
  WHITE = Color.resolve(:white)

  private def described = VBlank::Console.described(game_console)
  private def program
    skip_unless_written_for Everywhere::GAME
    Everywhere.program(console: game_console)
  end

  private def screen_after(frames) = game_player.run(program, frames: frames).screen

  # The columns of the title's row where its yellow letters are.
  private def title_columns(screen)
    rows = Everywhere::TITLE_ROW...(Everywhere::TITLE_ROW + 7)
    (0...described.screen_width).select { |x| rows.any? { |y| screen.pixel(x, y) == shown(YELLOW) } }
  end

  def test_the_title_is_centred_and_longer_on_the_super_nintendo
    columns = title_columns(screen_after(3))
    refute_empty columns, "the title is drawn"
    middle = described.screen_width / 2
    assert_in_delta middle, (columns.first + columns.last) / 2.0, 4, "centred on this screen"
    if game_console == :snes
      assert_operator columns.size, :>, 50, "SUPER BOUNCE"
    else
      assert_operator columns.size, :<, 40, "BOUNCE"
    end
  end

  # Long enough to reach a wall on every screen, and come back from it: the ball leaves the middle
  # two pixels a pass to the right and one down.
  def test_the_ball_bounces_back_from_the_walls_of_this_screen
    seen = []
    player = game_player
    player.each_vblank { seen << [player[:x], player[:y]] }
    player.run(program, frames: described.screen_width)
    xs, ys = seen.transpose
    assert_equal described.screen_width - Everywhere::BALL_SIZE, xs.max, "the ball reaches the right wall"
    assert_operator xs.last, :<, xs.max, "and comes back from it"
    assert_operator ys.max, :<=, described.screen_height - Everywhere::BALL_SIZE
  end

  def test_the_tune_plays_everywhere_but_the_super_nintendo
    player = game_player
    tune = []
    logged = 0
    player.each_vblank do
      player.audio.drop(logged).each { |kind, voice, _, pitch| tune << pitch if kind == :voice && voice == 1 && pitch.positive? }
      logged = player.audio.size
    end
    player.run(program, frames: 40)
    if game_console == :snes
      assert_empty tune
    else
      assert_includes tune, 262, "the tune's first note, C4"
    end
  end
end
