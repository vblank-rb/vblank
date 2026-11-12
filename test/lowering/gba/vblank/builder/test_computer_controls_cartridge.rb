# frozen_string_literal: true

require "test_helper"

# The keys and gamepad buttons a game adds for a computer (`computer_keys`, `computer_gamepad`)
# never reach a console's cartridge: the Advance's and the Color's are built byte for byte as
# without them.
class TestComputerControlsCartridge < Minitest::Test
  private def built(console, &block)
    VBlank.build("KEYS", console: console, out: StringIO.new, err: StringIO.new, &block)
  end

  def test_a_consoles_cartridge_is_the_same_with_them_or_without
    game = proc do
      screen :bitmap
      game_loop { fill_rect 0, 0, 8, 8, :red if held(:a) }
    end
    with_keys = proc do
      computer_keys a: :d, start: :space
      computer_gamepad a: :west
      screen :bitmap
      game_loop { fill_rect 0, 0, 8, 8, :red if held(:a) }
    end

    assert_equal built(:gba, &game).buffer, built(:gba, &with_keys).buffer
    assert_equal built(:gbc, &game).bytes, built(:gbc, &with_keys).bytes
  end
end
