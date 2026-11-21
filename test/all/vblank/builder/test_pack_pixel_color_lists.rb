# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"

# The game these tests play, registered in test/pack_games.rb too, so it is built with its pack left
# out as well and held to this build.
module PackPixelColorListGames
  include SharedConstants
  include MadeUpOriginalLayouts

  GENESIS = LAYOUTS.find { |layout| layout.platform == :genesis }
  BANK_SIZE = 4
  BANKS = Ractor.make_shareable(PALETTE.each_slice(BANK_SIZE).to_a)

  # Two 8x8 pictures kept one byte a pixel in a slot of pixels, each row the same: the first in
  # stripes of places 1, 2 and 3 from the left, the second the other way round. Place 0 is
  # see-through, at the first's left edge and the second's right edge.
  LEFT_ROW = [0, 1, 1, 2, 2, 2, 3, 3].freeze
  RIGHT_ROW = LEFT_ROW.reverse.freeze
  PIXEL_PLACES = Ractor.make_shareable([*LEFT_ROW * 8, *RIGHT_ROW * 8])
  SHIP_AT = [40, 40].freeze
  # The columns of the ship read: its left edge, then a column of each stripe of the first picture.
  COLUMNS = [0, 1, 4, 7].freeze

  # The game: one sprite showing the two pictures, each from the slot of pixels and given the list
  # :drawn by name, a bank of the pack's colours. Pass 1 shows the first picture, pass 2 the second,
  # and from pass 3 the sprite is drawn with :other, another bank. The program and the pack file.
  private def pixel_pictures_drawn_with_game_and_file(from, options: VBlank::Cartridge::Options.new)
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :tiled
      pack = data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.pixels :art, count: PIXEL_PLACES.length
        slots.fill_from_copy do |_copy, filled|
          PIXEL_PLACES.each_with_index { |place, at| filled[:art][at] = place }
        end
      end
      colors :drawn, pack[:palette].bank(1, size: BANK_SIZE)
      colors :other, pack[:palette].bank(2, size: BANK_SIZE)
      image :left, width: 8, height: 8, colors: :drawn, places: pack[:art].pixels(0, 64), see_through: 0
      image :right, width: 8, height: 8, colors: :drawn, places: pack[:art].pixels(64, 64), see_through: 0
      ship = sprite :ship, at: SHIP_AT, facing: { left: :left, right: :right }
      pass = var :pass, 0
      game_loop do
        pass += 1
        ship.face :right if pass == 2
        ship.draw_with :other if pass == 3
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end
end

# A picture from a slot of pixels given a list of colours by name (`image ..., colors: :drawn, places:
# pack[:art].pixels(...)`), so a sprite showing such pictures can be drawn with another list, as one
# showing pictures given their places can. A port's unpacking often writes its pictures a byte a
# pixel, and the original drew them in a bank of its colours it swapped for another.
#
# The answer key is the made-up original's own palette (MadeUpOriginalLayouts::PALETTE): bank n of
# four is its colours 4n to 4n + 3, and a pixel of place p shows colour p of the bank drawn with.
class TestPackPixelColorLists < Minitest::Test
  include PackPixelColorListGames

  # The ship's columns once pass +pass+ is drawn (Testing#framework_drawing_lag), and a pixel of the
  # screen nothing covers.
  private def columns_after(program, pass)
    screen = game_player.run(program, frames: pass + framework_drawing_lag).screen
    [COLUMNS.map { |column| screen.pixel(SHIP_AT.first + column, SHIP_AT.last + 1) }, screen.pixel(SHIP_AT.first - 10, SHIP_AT.last + 1)]
  end

  private def bank_colors(bank, places) = places.map { |place| shown(BANKS.fetch(bank).fetch(place)) }

  def test_a_sprite_of_pixel_pictures_in_a_named_list_shows_its_list_then_draws_with_another
    Dir.mktmpdir do |folder|
      program, = pixel_pictures_drawn_with_game_and_file(layout_original(folder, GENESIS))

      drawn, backdrop = columns_after(program, 1)
      assert_equal [backdrop, *bank_colors(1, [1, 2, 3])], drawn, "pass 1 shows the first picture in :drawn"
      drawn, = columns_after(program, 2)
      assert_equal [*bank_colors(1, [3, 3, 2]), backdrop], drawn, "pass 2 shows the second picture in :drawn"
      drawn, = columns_after(program, 3)
      assert_equal [*bank_colors(2, [3, 3, 2]), backdrop], drawn, "pass 3 shows the second picture in :other"
    end
  end

  # A list given by name has place 0 see-through, so a picture that draws place 0 cannot take one.
  def test_a_named_list_on_a_picture_that_draws_place_zero_is_refused
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      refused = assert_raises(ArgumentError) do
        Builder.new.instance_eval do
          pack = data_pack(from: from, version: "1") do |slots|
            slots.colors :palette, at: PALETTE_AT, count: 16
            slots.pixels :art, count: 64
            slots.fill_from_copy { |_copy, filled| 64.times { |at| filled[:art][at] = 1 } }
          end
          colors :drawn, pack[:palette].bank(1, size: BANK_SIZE)
          image :left, width: 8, height: 8, colors: :drawn, places: pack[:art].pixels(0, 64)
        end
      end

      assert_match "see_through: 0", refused.message
    end
  end
end
