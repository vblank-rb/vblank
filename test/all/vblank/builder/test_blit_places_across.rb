# frozen_string_literal: true

require "test_helper"

# A PICTURE PAINTED AT EVERY PLACE ACROSS. A console that draws in 8-pixel tiles keeps a picture
# ready for the places across it can be painted at (a Super Nintendo keeps its rows already
# shifted for each place modulo eight it can reach), so a picture at a written place, at a place
# worked out as the game runs, and at a column times eight plus a written number must each come out
# where the game put it. The picture is lopsided, so a pixel shifted by one shows. Kept inside the
# Game Boy Color's 160×144 screen.
class TestBlitPlacesAcross < Minitest::Test
  PATTERN = "##.#"
  RED = Color.resolve(:red)

  def test_a_picture_at_written_places_of_every_place_modulo_eight
    screen = shown(frames: 2) do
      game_loop do
        clear_screen :black
        8.times { |shift| blit :mark, 3 + (shift * 9), 10 }
      end
    end

    8.times { |shift| assert_mark_at screen, 3 + (shift * 9), 10 }
  end

  def test_a_picture_at_a_place_worked_out_as_the_game_runs
    8.times do |frame|
      screen = shown(frames: frame + 2) do
        x = 20
        game_loop do
          clear_screen :black
          blit :mark, x, 30
          x += 1
        end
      end

      assert_mark_at screen, 21 + frame, 30
    end
  end

  def test_a_picture_at_a_column_times_eight_plus_a_written_number
    screen = shown(frames: 3) do
      column = 2
      game_loop do
        clear_screen :black
        blit :mark, (column * 8) + 3, 50
        column += 5
      end
    end

    assert_mark_at screen, (12 * 8) + 3, 50
  end

  private def assert_mark_at(screen, x, y)
    PATTERN.each_char.with_index do |char, i|
      expected = char == "#" ? RED : 0
      assert_equal expected, screen.pixel(x + i, y), "the picture at (#{x}, #{y}), its pixel #{i}"
    end
    assert_equal 0, screen.pixel(x - 1, y), "nothing left of the picture at (#{x}, #{y})"
    assert_equal 0, screen.pixel(x + PATTERN.length, y), "nothing right of the picture at (#{x}, #{y})"
  end

  private def shown(frames:, &game)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image(:mark, "." => :transparent, "#" => :red) { PATTERN }
    end
    builder.instance_eval(&game)
    builder.finalize_program
    game_player.run(builder.program, frames: frames).screen
  end
end
