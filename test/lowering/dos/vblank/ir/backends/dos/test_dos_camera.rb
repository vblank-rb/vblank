# frozen_string_literal: true

require "test_helper"

# THE CAMERA ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun): every pixel of the
# picture the player is shown and where the view is. What the camera does is in
# test/all/vblank/builder/test_camera_shake.rb; these are what is DOS's own, where the processor makes the
# picture shown a row at a time: the view past each edge, a row the game changes while the view is moved,
# and sprites that stay where they are as the picture moves under them.
class TestDOSCamera < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # A strip whose every pixel differs from its neighbour's, so a row moved a pixel too far shows.
  STRIP = %i[red green blue white].freeze

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)
  private def checked(frames: nil, &game) = DOS::CheckedRun.new.run(program_of(&game), frames: frames)
  private def colors(*names) = names.map { |name| VBlank::Graphics::Color.resolve(name) }
  private def shown(run, *places) = places.map { |x, y| run.screen.pixel(x, y) }

  # The view moved right and down: the screen's top left shows what was drawn there, and the far edges
  # show the backdrop, where the picture has nothing.
  def test_the_view_moved_right_and_down_shows_the_backdrop_past_the_picture
    run = checked do
      screen :bitmap
      image :strip, width: 4, height: 1, data: STRIP
      clear_screen :blue
      blit :strip, 13, 7
      camera 13, 7
      halt
    end

    assert_equal colors(:red, :green, :blue, :white), shown(run, [0, 0], [1, 0], [2, 0], [3, 0])
    assert_equal colors(:blue, :black, :black), shown(run, [306, 100], [307, 100], [100, run.screen.height - 7])
  end

  # The same the other way, where the backdrop is at the left and the top.
  def test_the_view_moved_left_and_up_shows_the_backdrop_before_the_picture
    run = checked do
      screen :bitmap
      image :strip, width: 4, height: 1, data: STRIP
      clear_screen :blue
      blit :strip, 0, 0
      camera(-5, -3)
      halt
    end

    assert_equal colors(:black, :black, :red, :white, :blue), shown(run, [4, 3], [5, 2], [5, 3], [8, 3], [9, 3])
  end

  # A view a whole screen away or more, either way, is all backdrop, and one put back shows the picture.
  def test_a_view_past_the_whole_picture_is_backdrop_until_it_comes_back
    run = checked(frames: 8) do
      screen :bitmap
      clear_screen :green
      passes = var :passes, 0
      game_loop do
        passes += 1
        camera 320, 0 if passes == 1
        camera(-100_000, 5) if passes == 2
        camera 0, 70_000 if passes == 3
        camera 3, -2_000_000_000 if passes == 4
        camera 0, 0 if passes == 5
      end
    end

    assert_equal colors(:green, :green), shown(run, [0, 0], [319, 199])
  end

  # While the view is moved, what the game paints shows where the view puts it, and a view that moves
  # every pass is right on each.
  def test_a_game_that_paints_while_its_view_moves
    run = checked(frames: 30) do
      screen :bitmap
      image :strip, width: 4, height: 1, data: STRIP
      clear_screen :blue
      across = var :across, -12
      down = var :down, 9
      at = var :at, 0
      game_loop do
        across += 1
        down -= 1 if (at & 1) == 0
        camera across, down
        draw_rect_at 40, at, 9, 2, :white
        blit :strip, at, 100
        at += 5
      end
    end

    assert_equal 18, run[:across]
  end

  # A sprite over the picture stays where the game put it, and a painted one moves with the picture.
  def test_a_sprite_over_the_picture_stays_as_the_picture_moves_under_it
    run = checked(frames: 10) do
      screen :bitmap
      image :block, width: 4, height: 4, data: [:white] * 16
      image :mark, width: 4, height: 4, data: [:red] * 16
      clear_screen :blue
      over = sprite :block, at: [100, 50], over_picture: true
      sprite :mark, at: [200, 50]
      passes = var :passes, 0
      game_loop do
        passes += 1
        camera 6, 0 if passes == 3
        over.x += 1 if passes > 6
      end
    end

    assert_equal colors(:white, :red, :blue), shown(run, [105, 50], [194, 50], [200, 50])
  end

  # A game with no camera is shown its own picture, and carries none of this.
  def test_a_game_with_no_camera_has_no_second_picture
    plain = DOS.new.build(program_of { screen(:bitmap) && clear_screen(:blue) && halt })

    refute plain.built.runtime.key?(DOS::Runtime::Camera::SHOWN_X)
  end
end
