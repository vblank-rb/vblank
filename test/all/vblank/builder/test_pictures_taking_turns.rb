# frozen_string_literal: true

require "test_helper"

# A painted screen cleared every pass that paints one of two pictures in turn: a console may keep
# both and swap between them (the Super Nintendo does), so each pass must still show exactly the
# picture it painted — after the second picture changes, when one picture paints over the other's
# place, and when three take turns. Every run checks its picture against the interpreter's on
# every pass; the pixels asserted here say what that picture is.
class TestPicturesTakingTurns < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  BLACK = VBlank::Graphics::Color.resolve(:black)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The pixel at (+x+, +y+) after each of +frames+. Each place read is on the smallest screen a
  # run plays as (the Game Boy Color's, 160 by 144), so the right picture is read at x 140.
  private def pixels(frames, x, y, &game)
    built = program(&game)
    frames.map { |count| game_player.run(built, frames: count).screen.pixel(x, y) }
  end

  def test_two_halves_in_turn
    left = pixels([6, 7, 8], 20, 20) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        fill_rect 0, 0, 120, 160, :red if n % 2 == 0
        fill_rect 120, 0, 120, 160, :green if n % 2 == 1
        n += 1
      end
    end

    assert_equal 2, left.uniq.length, "the left half is red on one pass and black on the next"
    assert_includes left, RED
    assert_includes left, BLACK
  end

  # The second picture is a new colour from the sixth pass on: the screen shows that colour, not
  # the picture it showed two passes before.
  def test_the_second_picture_changing
    right = pixels([8, 9, 10, 11], 140, 20) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        if n % 2 == 0
          fill_rect 0, 0, 120, 160, :red
        elsif n < 6
          fill_rect 120, 0, 120, 160, :green
        else
          fill_rect 120, 0, 120, 160, :blue
        end
        n += 1
      end
    end

    refute_includes right, GREEN
    assert_includes right, BLUE
  end

  # The two pictures share a band of the screen, so each paints over tiles the other showed.
  def test_two_pictures_over_one_place
    band = pixels([6, 7, 8, 9], 110, 20) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        fill_rect 0, 0, 130, 160, :red if n % 2 == 0
        fill_rect 100, 0, 140, 160, :green if n % 2 == 1
        n += 1
      end
    end

    assert_includes band, RED
    assert_includes band, GREEN
  end

  def test_three_pictures_in_turn
    corner = pixels([6, 7, 8, 9], 10, 10) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        fill_rect 0, 0, 80, 160, :red if n % 3 == 0
        fill_rect 80, 0, 80, 160, :green if n % 3 == 1
        fill_rect 160, 0, 80, 160, :blue if n % 3 == 2
        n += 1
      end
    end

    assert_includes corner, RED
    assert_includes corner, BLACK
  end

  # Words that stay, and a prompt under them shown on every other pass.
  def test_a_prompt_that_blinks_under_words
    prompt = pixels([6, 7, 8, 9], 60, 100) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        draw_text "GAME OVER", 60, 40, :red
        fill_rect 60, 100, 60, 8, :white if n % 2 == 0
        n += 1
      end
    end

    assert_includes prompt, WHITE
    assert_includes prompt, BLACK
  end

  # The cleared colour changes, and then the screen paints a picture it painted on the old colour:
  # it is shown on the new one, here just under the right picture, in the row of tiles its bottom
  # edge crosses. (The fourth pass paints the left picture again, so the fifth's, the right, is
  # the one painted two pictures before, on black.)
  def test_a_picture_painted_again_after_the_clear_colour_changes
    below = pixels([5, 6, 7, 8], 140, 102) do
      screen :bitmap
      n = 0
      game_loop do
        if n < 3
          clear_screen :black
        else
          clear_screen :blue
        end
        if n % 2 == 0 || n == 3
          fill_rect 0, 0, 120, 100, :red
        else
          fill_rect 120, 0, 120, 100, :green
        end
        n += 1
      end
    end

    assert_equal [BLUE], below.uniq
  end
end
