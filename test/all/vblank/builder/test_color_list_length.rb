# frozen_string_literal: true

require "test_helper"

# A `colors` list can name sixteen on every console. A console whose own lists are shorter takes
# what each tile uses from it, so the list's length is not what decides whether it fits: the art
# refuses a tile that truly does not.
class TestColorListLength < Minitest::Test
  private def declare_colors(console, count)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    builder.colors(:long, [:transparent] + Array.new(count - 1) { :red })
  end

  def test_every_console_takes_a_list_of_sixteen_and_no_more
    %i[gba gbc snes].each do |console|
      assert_equal :long, declare_colors(console, 16)
      error = assert_raises(ArgumentError) { declare_colors(console, 17) }

      assert_match(/2 to 16 colors/, error.message)
    end
  end
end
