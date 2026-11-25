# frozen_string_literal: true

require "test_helper"

# A number the game keeps, put in drawn text as Ruby puts one in a String (`"HP #{hp}"`, `hp.to_s`),
# draws as the words and a `draw_number` of it written by hand would: the number in the room
# `draw_number` gives it, where the words before it end.
class TestTextWithNumbers < Minitest::Test
  # The pixels of the strip the text is drawn in, after +frames+ passes.
  private def strip_after(frames, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    (8..20).flat_map { |y| (0..80).map { |x| player.screen.pixel(x, y) } }
  end

  # hp counts up from 3, a pass at a time: the text shows the number the game holds.
  def test_a_number_put_in_text_draws_as_words_and_draw_number_would
    interpolated = strip_after(3) do
      screen :bitmap
      hp = 3
      game_loop do
        clear_screen :black
        hp += 1
        draw_text "HP #{hp}", 10, 10, :white, digits: 1
      end
    end
    by_hand = strip_after(3) do
      screen :bitmap
      hp = 3
      game_loop do
        clear_screen :black
        hp += 1
        # "HP " is three characters of six pixels, so the number starts 18 pixels on.
        draw_text "HP", 10, 10, :white
        draw_number hp, 28, 10, :white, digits: 1
      end
    end

    assert_equal by_hand, interpolated
    refute_equal [interpolated.first] * interpolated.length, interpolated
  end

  # On a tiled screen the words and the number are drawn once and the number follows hp.
  def test_a_number_put_in_tiled_text_follows_it_as_draw_number_does
    interpolated = strip_after(4) do
      screen :tiled
      hp = 3
      draw_text "HP #{hp}", 10, 10, :white, digits: 1
      game_loop { hp += 1 }
    end
    by_hand = strip_after(4) do
      screen :tiled
      hp = 3
      draw_text "HP", 10, 10, :white
      draw_number hp, 28, 10, :white, digits: 1
      game_loop { hp += 1 }
    end

    assert_equal by_hand, interpolated
  end

  def test_a_number_made_text_with_to_s_draws_as_draw_number_would
    turned = strip_after(2) do
      screen :bitmap
      hp = 3
      game_loop do
        clear_screen :black
        hp += 2
        draw_text hp.to_s, 10, 10, :white, digits: 1
      end
    end
    by_hand = strip_after(2) do
      screen :bitmap
      hp = 3
      game_loop do
        clear_screen :black
        hp += 2
        draw_number hp, 10, 10, :white, digits: 1
      end
    end

    assert_equal by_hand, turned
  end

  # Text holding a number the game works out has no letters while building, so anything but
  # drawing it is refused.
  def test_text_with_a_game_number_used_as_a_string_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      strip_after(1) do
        screen :bitmap
        hp = 3
        game_loop do
          hp += 1
          label = "HP #{hp}"
          draw_text label.upcase, 10, 10, :white
        end
      end
    end

    assert_match(/draw_text/, error.message)
  end
end
