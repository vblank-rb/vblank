# frozen_string_literal: true

require "test_helper"

# A `colors` list holds what the console's own lists hold, so one too long is refused while the
# author is looking at the line, on the console it cannot be shown on.
class TestColorListLength < Minitest::Test
  private def declare_colors(console, count)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    builder.colors(:long, [:transparent] + Array.new(count - 1) { :red })
  end

  def test_each_console_is_held_to_its_own_list
    { gba: 16, gbc: 4, snes: 16 }.each do |console, most|
      assert_equal :long, declare_colors(console, most), "#{console} holds #{most}"
      error = assert_raises(ArgumentError) { declare_colors(console, most + 1) }

      assert_match(/2 to #{most} colors/, error.message)
    end
  end
end
