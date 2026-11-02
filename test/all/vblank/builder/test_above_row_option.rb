# frozen_string_literal: true

require "test_helper"

# `above_row:` as far as every console agrees: what number it takes, and what a console that cannot
# do it yet says. What it does is test/console/snes/vblank/builder/test_background_above_row.rb.
class TestAboveRowOption < Minitest::Test
  private def held_background(console, row, err: StringIO.new)
    VBlank.build("HELD", console: console, out: StringIO.new, err: err) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      background :bar, tiles: :set, map: ["#" * 8], above_row: row
      game_loop { nil }
    end
  end

  def test_a_console_that_cannot_do_it_refuses_in_plain_words
    %i[gba gbc genesis].each do |console|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) { held_background(console, 32, err: said) }

      assert_match(/above_row/, said.string)
    end
  end

  def test_a_row_off_the_screen_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { held_background(:snes, 9000) }

    assert_match(/not a row of the screen/, error.message)
  end

  def test_a_row_worked_out_as_the_game_runs_is_refused
    assert_raises(ArgumentError) { held_background(:snes, :thirty_two) }
  end
end
