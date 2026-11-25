# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"

# A color game's tiles, read from its data pack, go into the color's cartridge as the original keeps
# them. A tile drawn by place from a list of four colours is kept place for place
# (GBC::Art#places_kept?), so the made-up Color original's tile bytes (MadeUpOriginalLayouts) are in
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
