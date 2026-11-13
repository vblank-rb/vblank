# frozen_string_literal: true

require "test_helper"

# `screen :bitmap, shown_rows: 32...192` — what a game is told when it gives up rows of the screen
# where that cannot be done: a range that is not rows of the screen, a screen that is not painted,
# a later screen line, a console that has nothing to gain from it. What the picture looks like on
# the Super Nintendo is test/console/snes/vblank/builder/test_screen_shown_rows_on_the_super_nintendo.rb,
# and what it gains there test/lowering/snes/vblank/ir/backends/snes/test_snes_shown_rows.rb.
class TestScreenShownRows < Minitest::Test
  Answers = VBlank::IR::Guardrails::Checks::ConsoleAnswers

  private def game(consoles = %i[snes], &block) = VBlank.game("SHORTPICTURE", consoles: consoles, &block)

  private def refusal(&block)
    assert_raises(ArgumentError) { game(&block).program }
  end

  def test_rows_that_are_not_a_range_are_refused
    error = refusal { screen :bitmap, shown_rows: 32 }

    assert_match(/shown_rows: 32/, error.message)
  end

  def test_rows_past_the_screen_are_refused
    error = refusal { screen :bitmap, shown_rows: 32...300 }

    assert_match(/224/, error.message)
  end

  def test_rows_of_no_row_are_refused
    error = refusal { screen :bitmap, shown_rows: 40...40 }

    assert_match(/no row/, error.message)
  end

  def test_shown_rows_are_refused_on_a_tiled_screen
    error = refusal { screen :tiled, shown_rows: 32...192 }

    assert_match(/screen :bitmap/, error.message)
  end

  def test_shown_rows_are_refused_on_a_later_screen_line
    error = refusal do
      screen :bitmap
      screen :bitmap, shown_rows: 32...192
    end

    assert_match(/first `screen`/, error.message)
  end

  def test_a_tiled_screen_is_refused_in_a_game_that_gives_up_rows
    error = refusal do
      screen :bitmap, shown_rows: 32...192
      scene(:map) { screen :tiled }
    end

    assert_match(/shown_rows:/, error.message)
  end

  # Every row is the screen as it is: the game builds as if it had said nothing.
  def test_every_row_is_the_screen_as_it_is
    whole = game do
      screen :bitmap, shown_rows: 0...224
      game_loop { clear_screen :blue }
    end.program
    plain = game do
      screen :bitmap
      game_loop { clear_screen :blue }
    end.program

    assert_nil whole.shown_rows
    assert_equal plain.described_console, whole.described_console
  end

  # Every console but the Super Nintendo refuses it in its own words, naming the part.
  def test_each_console_that_cannot_give_up_rows_refuses_them
    %i[gba gbc genesis ps1].each do |console|
      made = game(%i[snes] + [console]) do
        screen :bitmap, shown_rows: 16...128
        game_loop { clear_screen :blue }
      end
      found = Answers.new.detect(made.program(console: console))

      refused = found.find { |finding| finding.message.include?("shown_rows") }
      assert refused, "#{console} says nothing of shown_rows"
      assert_equal :error, refused.severity
    end
  end

  def test_the_super_nintendo_takes_shown_rows
    made = game do
      screen :bitmap, shown_rows: 32...192
      game_loop { clear_screen :blue }
    end

    assert_empty Answers.new.detect(made.program(console: :snes))
  end

  # Big pixels count rows in the small picture, which no console that gives up rows shows.
  def test_shown_rows_beside_big_pixels_are_refused
    error = assert_raises(ArgumentError) do
      game(%i[gba]) { screen :bitmap, pixel_size: 2, shown_rows: 16...64 }.program
    end

    assert_match(/pixel_size: 2/, error.message)
  end
end
