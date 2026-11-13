# frozen_string_literal: true

require "test_helper"

# `above_row:` as far as every console agrees: what number it takes, and what a console that cannot
# do it yet says. What it does is test/console/snes/vblank/builder/test_background_above_row.rb.
class TestAboveRowOption < Minitest::Test
  # A background held above +row+, with +settings+ besides (`alone: true`).
  private def held_background(console, row, err: StringIO.new, **settings)
    VBlank.build("HELD", console: console, out: StringIO.new, err: err) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      background :bar, tiles: :set, map: ["#" * 8], above_row: row, **settings
      game_loop { nil }
    end
  end

  # The settings a held background is refused with, plain and shown alone.
  SETTINGS = [{}, { alone: true }, { alone: :without_sprites }].freeze

  def test_a_console_that_cannot_do_it_refuses_in_plain_words
    %i[gba gbc genesis].each do |console|
      SETTINGS.each do |settings|
        said = StringIO.new
        assert_raises(VBlank::BuildError, console.to_s) { held_background(console, 32, err: said, **settings) }

        assert_match(/above_row/, said.string)
      end
    end
  end

  def test_alone_without_a_row_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { held_background(:snes, nil, alone: true) }

    assert_match(/no `above_row:`/, error.message)
  end

  def test_alone_that_is_not_true_or_false_is_refused
    error = assert_raises(ArgumentError) { held_background(:snes, 32, alone: :yes) }

    assert_match(/must be true, false or :without_sprites/, error.message)
  end

  def test_a_row_off_the_screen_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { held_background(:snes, 9000) }

    assert_match(/not a row of the screen/, error.message)
  end

  # Two backgrounds shown alone above a row on one screen: only one can be, whichever way each is
  # alone, so the build stops naming both.
  def test_two_backgrounds_shown_alone_on_one_screen_are_refused_in_plain_words
    [true, :without_sprites].each do |alone|
      err = StringIO.new
      assert_raises(VBlank::BuildError, alone.inspect) do
        VBlank.build("TWOALONE", console: :snes, out: StringIO.new, err: err) do
          screen :tiled
          image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
          tiles :set, "#" => :tile
          background :score, tiles: :set, map: ["#" * 8], above_row: 32, alone: alone
          background :lives, tiles: :set, map: ["#" * 8], above_row: 16, alone: true
          game_loop { nil }
        end
      end

      assert_match(/:score and :lives alone above a row/, err.string, alone.inspect)
    end
  end

  def test_a_row_worked_out_as_the_game_runs_is_refused
    assert_raises(ArgumentError) { held_background(:snes, :thirty_two) }
  end
end
