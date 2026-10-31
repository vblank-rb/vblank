# frozen_string_literal: true

require "test_helper"

# A character the font does not have used to leave a gap and say nothing, so a line reading "100%"
# showed "100 " and only a look at the picture found it. Words written in the game are known while
# it is built, so the build says so instead.
class TestTextMissingCharacter < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The pixels of +text+ in the default font at the top left of a bitmap screen: true where lit.
  private def lit(text, width)
    game = program do
      screen :bitmap
      draw_text text, 0, 0, :white
      game_loop {}
    end
    shown = game_player.run(game, frames: 2).screen
    white = VBlank::Graphics::Color.resolve(:white)
    Array.new(7) { |y| Array.new(width) { |x| shown.pixel(x, y) == white } }
  end

  def test_words_with_a_character_the_font_lacks_are_a_friendly_error
    error = assert_raises(ArgumentError) do
      program do
        screen :bitmap
        draw_text "1 OF 2 @ HOME", 0, 0, :white
      end
    end

    assert_match(/font :default has no "@"/, error.message)
    assert_match(/1 OF 2 @ HOME/, error.message)
  end

  def test_every_character_missing_is_named_once
    error = assert_raises(ArgumentError) do
      program do
        screen :bitmap
        draw_text "12", 0, 0, :white, font: :tiny
        draw_text "A1B A", 0, 0, :white, font: :tiny
      end
    end

    assert_match(/font :tiny has no "A", "B"/, error.message)
  end

  def test_a_tiled_screen_says_the_same
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        draw_text "#1", 0, 0, :white
      end
    end

    assert_match(/font :default has no "#"/, error.message)
  end

  # What an end-of-floor screen reaches for first: each of these draws something of its own.
  def test_the_default_font_holds_the_marks_a_score_screen_needs
    %w[% , ' ? /].each do |mark|
      assert lit(mark, 5).flatten.any?, "#{mark} draws"
    end
  end

  def test_the_marks_differ_from_each_other
    pictures = %w[% , ' ? / .].map { |mark| lit(mark, 5) }

    assert_equal pictures.length, pictures.uniq.length
  end

  # A font that folds to capitals still has the small letters.
  def test_small_letters_fold_to_capitals_and_are_not_missing
    assert lit("a", 5).flatten.any?
  end
end
