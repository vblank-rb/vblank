# frozen_string_literal: true

require "test_helper"

# READING A CONSOLE'S OWN LAYOUT (IR::FormatReading). The tiles and colours each lowering writes are
# held in that lowering's own folder (test_gbc_format_reading.rb and its siblings).
class TestFormatReading < Minitest::Test
  Reading = VBlank::IR::FormatReading
  Genesis = VBlank::Console::GenesisHardware

  # A colour the Genesis's lowering writes into its colour memory (GenesisHardware.color_word),
  # read back in the Genesis's layout, is the colour the Genesis shows (GenesisHardware.shown_color).
  def test_a_genesis_colour_reads_back_as_the_genesis_shows_it
    colors = (0...0x8000).step(97).to_a
    kept = colors.map { |color| Genesis.color_word(color) }.pack("n*")

    assert_equal colors.map { |color| Genesis.shown_color(color) }, Reading.colors(kept, Genesis::ORIGINAL_FORMATS.colors)
  end
end
