# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_backdrops"

# A BACKDROP TAKEN FROM THE DATA PACK IS THE BACKDROP THAT COLOUR WRITTEN OUT WOULD BE, so the
# Advance's cartridge of a game taking its backdrops from the pack is, byte for byte, the cartridge
# of the same game with the colours written in it: on the game's own `screen` line, and on each
# scene's under a tint, where the build keeps the backdrops in a table of their own
# (GBA::PaletteTint#prepare_screen_backdrops). What the games show is held by
# test/all/vblank/builder/test_pack_backdrops.rb and its twin in test/console/gba/.
class TestPackBackdropsCartridge < Minitest::Test
  include PackBackdropGames

  def test_a_backdrop_from_the_pack_builds_the_cartridge_the_color_written_out_builds
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      packed = assemble_rom(game_with_backdrop(from) { |pack| { backdrop: pack[:palette] } })
      written = assemble_rom(game_with_backdrop(from) { |_pack| { backdrop: BANKS[0][0] } })

      assert_equal written.buffer, packed.buffer
    end
  end

  def test_scenes_with_backdrops_from_the_pack_build_the_cartridge_the_colors_written_out_build
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      packed = assemble_rom(scenes_with_backdrops(from))
      written = assemble_rom(scenes_with_backdrops(from, written_out: true))

      assert_equal written.buffer, packed.buffer
    end
  end
end
