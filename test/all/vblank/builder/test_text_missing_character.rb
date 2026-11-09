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

  # A String is made while the game is built, so a number the game keeps cannot go in one; the
  # build names what was written rather than a `#` the font lacks.
  def test_a_game_number_put_into_the_words_is_a_friendly_error
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      program do
        screen :bitmap
        hp = 3
        game_loop do
          draw_text "HP #{hp}", 0, 0, :white
          hp -= 1
        end
      end
    end

    assert_match(/`\#\{\.\.\.\}`/, error.message)
    assert_match(/draw_number/, error.message)
  end

  # A plain number put into the words in the game's own code is Ruby's, worked out while building.
  def test_a_plain_number_put_into_the_words_is_drawn
    game = program do
      screen :bitmap
      lives = 3
      game_loop { draw_text "LIVES #{lives}", 0, 0, :white }
    end
    shown = game_player.run(game, frames: 2).screen
    white = VBlank::Graphics::Color.resolve(:white)
    drawn = Array.new(7) { |y| Array.new(40) { |x| shown.pixel(x, y) == white } }

    assert_equal lit("LIVES 3", 40), drawn
  end

  # A heredoc's lines are words too, made while the game is built, so a game number put into them
  # is refused as a one-line String's is.
  def test_a_game_number_put_into_a_heredoc_is_a_friendly_error
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      program do
        screen :bitmap
        hp = 3
        game_loop do
          words = <<~WORDS.chomp
            HP #{hp} LEFT
          WORDS
          draw_text words, 0, 0, :white
          hp -= 1
        end
      end
    end

    assert_match(/`\#\{\.\.\.\}`/, error.message)
    assert_match(/draw_number/, error.message)
  end

  # ...and a plain number in a heredoc is Ruby's, worked out while building.
  def test_a_plain_number_put_into_a_heredoc_is_drawn
    game = program do
      screen :bitmap
      lives = 3
      level = 2
      game_loop do
        words = <<~WORDS.chomp
          LIVES #{lives} LV #{level}
        WORDS
        draw_text words, 0, 0, :white
      end
    end
    shown = game_player.run(game, frames: 2).screen
    white = VBlank::Graphics::Color.resolve(:white)
    drawn = Array.new(7) { |y| Array.new(70) { |x| shown.pixel(x, y) == white } }

    assert_equal lit("LIVES 3 LV 2", 70), drawn
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
