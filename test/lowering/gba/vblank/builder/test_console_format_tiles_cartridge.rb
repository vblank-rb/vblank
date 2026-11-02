# frozen_string_literal: true

require "test_helper"
require "stringio"

# `console_format: true` ON THE ADVANCE. A list already holds what the Advance's video memory holds,
# so the word has nothing to skip: the cartridge is the same to the byte, and no Advance game pays
# for the option the other consoles have.
class TestConsoleFormatTilesCartridge < Minitest::Test
  private def cartridge(**word)
    VBlank.build("OWNFORM", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte, full_of: 0x11
      box = tiles :box, from: canvas, count: 2, colors: :ink, **word
      background :front, tiles: :box, map: [[1, 2]]
      game_loop { box.changed }
    end
  end

  def test_the_word_changes_no_byte_of_an_advance_cartridge
    assert_equal cartridge.buffer, cartridge(console_format: true).buffer
  end
end
