# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_data_pack_layouts"

# A COLOR GAME'S TILES, READ FROM ITS DATA PACK, GO INTO THE COLOR'S CARTRIDGE AS THE ORIGINAL KEEPS
# THEM. A tile drawn by place from a list of four colours is kept place for place
# (GBC::Art#kept_places?), so the made-up Color original's tile bytes (MadeUpOriginalLayouts) are in
# the cartridge unchanged.
class TestGBCPackLayouts < Minitest::Test
  include MadeUpOriginalLayouts

  def test_a_color_originals_tiles_are_in_the_cartridge_byte_for_byte
    layout = LAYOUTS.find { |each| each.platform == :gbc }
    Dir.mktmpdir do |folder|
      program, = layout_game(through_layout_pack(layout_original(folder, layout), layout))
      cartridge = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "LAYOUT").buffer.b

      layout.tiles.each_with_index do |places, at|
        assert_includes cartridge, layout.tile_encoder.(places), "tile #{at} is in the cartridge as the original keeps it"
      end
    end
  end
end
