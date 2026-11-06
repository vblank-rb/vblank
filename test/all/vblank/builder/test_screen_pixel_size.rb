# frozen_string_literal: true

require "test_helper"

# `screen :bitmap, pixel_size: 2` — what a game is told when it asks for big pixels where they
# cannot be made: on a screen that is not painted, on a later screen line, on a console that cannot
# show a pixel bigger. What is not made yet for big pixels is
# test/all/vblank/ir/guardrails/test_ir_guardrail_bigger_pixels_not_made_yet.rb. What the picture looks like on the Advance is test/console/gba/vblank/builder/
# test_screen_pixel_size_on_the_advance.rb.
class TestScreenPixelSize < Minitest::Test
  Answers = VBlank::IR::Guardrails::Checks::ConsoleAnswers

  private def game(consoles = %i[gba], &block) = VBlank.game("BIGPIXELS", consoles: consoles, &block)

  private def refusal(&block)
    assert_raises(ArgumentError) { game(&block).program }
  end

  def test_a_size_other_than_one_or_two_is_refused
    error = refusal { screen :bitmap, pixel_size: 3 }

    assert_match(/pixel_size: 3/, error.message)
  end

  def test_big_pixels_are_refused_on_a_tiled_screen
    error = refusal { screen :tiled, pixel_size: 2 }

    assert_match(/screen :bitmap/, error.message)
  end

  def test_big_pixels_are_refused_on_a_later_screen_line
    error = refusal do
      screen :bitmap
      screen :bitmap, pixel_size: 2
    end

    assert_match(/first `screen`/, error.message)
  end

  def test_big_pixels_are_refused_after_the_game_reads_the_screen_size
    error = refusal do
      screen_width
      screen :bitmap, pixel_size: 2
    end

    assert_match(/screen_width/, error.message)
  end

  def test_a_tiled_screen_is_refused_in_a_game_of_big_pixels
    error = refusal do
      screen :bitmap, pixel_size: 2
      scene(:map) { screen :tiled }
    end

    assert_match(/pixel_size: 2/, error.message)
  end

  def test_a_size_of_one_is_the_screen_as_it_is
    sizes = []
    game do
      screen :bitmap, pixel_size: 1
      sizes << screen_width << screen_height
    end.program

    assert_equal [240, 160], sizes
  end

  # Every console but the Advance refuses big pixels in its own words, naming the part.
  def test_each_console_that_cannot_show_big_pixels_refuses_them
    %i[gbc snes genesis ps1].each do |console|
      made = game(%i[gba] + [console]) do
        screen :bitmap, pixel_size: 2
        game_loop { clear_screen :blue }
      end
      found = Answers.new.detect(made.program(console: console))

      refused = found.find { |finding| finding.message.include?("pixel_size") }
      assert refused, "#{console} says nothing of pixel_size"
      assert_equal :error, refused.severity
    end
  end

  def test_the_advance_takes_big_pixels
    made = game do
      screen :bitmap, pixel_size: 2
      game_loop { clear_screen :blue }
    end

    assert_empty Answers.new.detect(made.program(console: :gba))
  end
end
