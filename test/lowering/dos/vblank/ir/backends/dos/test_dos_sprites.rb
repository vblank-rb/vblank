# frozen_string_literal: true

require "test_helper"

# SPRITES OVER A PAINTED PICTURE ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun):
# every pixel of the picture the player is shown, the card's own memory a pass later, and which sprites
# were placed and where. What such a sprite does is in test/all/vblank/builder/test_sprite_over_picture.rb,
# which this run plays too; these are what is DOS's own: the screen's own width, and what is refused.
class TestDOSSprites < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  RED = (["####"] * 4).join("\n")

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)
  private def checked(frames:, &game) = DOS::CheckedRun.new.run(program_of(&game), frames: frames)
  private def color(name) = VBlank::Graphics::Color.resolve(name)

  # A sprite standing still, with a picture nobody paints again, is a pass in which nothing is copied: the
  # run still agrees on every pass, and the card still shows it.
  def test_a_sprite_standing_still_over_a_picture_left_alone
    run = checked(frames: 6) do
      screen :bitmap
      image :block, width: 6, height: 6, data: [:white] * 36
      clear_screen :blue
      sprite :block, at: [314, 194], over_picture: true
      passes = var :passes, 0
      game_loop { passes += 1 }
    end

    assert_equal color(:white), run.screen.pixel(319, 199), "the last pixel of a screen 320 wide and 200 high"
  end

  # Sprites that move a pass, stand a pass and move again, over a picture painted again on some passes only.
  def test_sprites_that_move_on_some_passes_over_a_picture_painted_on_others
    checked(frames: 12) do
      screen :bitmap
      image :block, width: 6, height: 6, data: [:white] * 36
      clear_screen :blue
      one = sprite :block, at: [10, 10], over_picture: true
      other = sprite :block, at: [200, 150], over_picture: true
      passes = var :passes, 0
      game_loop do
        one.x += 3 if (passes & 1) == 0
        other.y -= 2 if (passes & 3) == 3
        fill_rect 0, 0, 40, 40, :red if passes == 5
        fill_rect 180, 100, 60, 60, :green if passes == 8
        passes += 1
      end
    end
  end

  # A sprite of several pictures shows the one its pose picks, as the game changes it.
  def test_a_sprite_shows_the_picture_its_facing_picks
    run = checked(frames: 8) do
      screen :bitmap
      image :facing_right, width: 4, height: 4, data: [:red] * 16
      image :facing_left, width: 4, height: 4, data: [:green] * 16
      clear_screen :blue
      walker = sprite :walker, at: [100, 80], facing: { right: :facing_right, left: :facing_left }, over_picture: true
      passes = var :passes, 0
      game_loop do
        walker.move :right, by: 3 if passes < 4
        walker.move :left, by: 3 if passes >= 4
        passes += 1
      end
    end

    assert_equal [:facing_left], run.sprites.map(&:picture)
  end

  # A game that paints its whole picture again every pass paints over no sprite.
  def test_a_picture_painted_again_every_pass_paints_over_no_sprite
    run = checked(frames: 6) do
      screen :bitmap
      image :block, width: 6, height: 6, data: [:white] * 36
      marker = sprite :block, at: [10, 10], over_picture: true
      game_loop do
        clear_screen :blue
        fill_rect 0, 0, 40, 40, :red
        marker.x += 1
      end
    end

    assert_equal color(:white), run.screen.pixel(run.sprites.first.x, 10)
  end

  # A SPRITE PAINTED INTO THE PICTURE (the plain `sprite` of a painted screen) keeps the patch under it and
  # puts it back before it moves on. One that walks off the right of a screen 320 wide and back keeps and
  # puts back patches that are part off the screen, and leaves the picture as it was painted.
  def test_a_sprite_painted_into_the_picture_walks_off_the_screen_and_back
    run = checked(frames: 30) do
      screen :bitmap
      image :block, width: 6, height: 6, data: [:white] * 36
      clear_screen :blue
      fill_rect 280, 96, 40, 4, :yellow
      walker = sprite :block, at: [300, 95]
      passes = var :passes, 0
      game_loop do
        walker.x += 2 if passes < 15
        walker.x -= 2 if passes >= 15
        passes += 1
      end
    end

    assert_equal [color(:yellow), color(:blue)], [run.screen.pixel(319, 97), run.screen.pixel(319, 95)]
  end
end
