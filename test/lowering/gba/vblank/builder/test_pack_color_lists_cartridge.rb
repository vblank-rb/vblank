# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_color_lists"

# A LIST OF COLOURS FROM THE DATA PACK IS THE LIST THOSE COLOURS WRITTEN OUT WOULD BE, so the
# Advance's cartridge of a game taking its lists from the pack is, byte for byte, the cartridge of
# the same game with the colours written in it. What the two show is held on every run by
# test/all/vblank/builder/test_pack_color_lists.rb.
class TestPackColorListsCartridge < Minitest::Test
  include PackColorListGames

  def test_lists_from_the_pack_build_the_cartridge_the_colors_written_out_build
    Dir.mktmpdir do |folder|
      packed = assemble_rom(recoloring_game(banks_from_pack(layout_original(folder, GENESIS))))
      written = assemble_rom(recoloring_game(banks_written_out))

      assert_equal written.buffer, packed.buffer
    end
  end
end
