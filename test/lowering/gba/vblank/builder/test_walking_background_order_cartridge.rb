# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND THAT WALKS BETWEEN AREAS BESIDE ONE THAT STAYS, ON THE ADVANCE'S CARTRIDGE, in both
# orders of declaration. The build keeps two tiles of the same pixels once, so a walking background
# declared after one that stays can find every tile of every area in video memory already, and
# then its areas hold no tiles of their own to bring in: walking is the map and the colours alone.
class TestWalkingBackgroundOrderCartridge < Minitest::Test
  include Differential

  WALKS_OUT = 4  # the pass that walks into the house
  WALKS_BACK = 8 # ...and the pass that walks back to the field
  ROUND_THE_WALKS = (1..(WALKS_BACK + 3))

  # A ground of two areas, a row of grass in the field and a row of floor in the house, and a
  # sign of two tiles that stays. +pictures+ is each tile's rows of pixels: every tile is in one
  # colour of its own, so tiles given the same rows are the same pixels in different colours.
  private def walking_game(walking_first:, pictures:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      { grass: :green, floor: :red, board: :white }.each do |name, color|
        image(name, "#" => color, "." => :transparent) { pictures.fetch(name).join("\n") }
      end
      tiles :field, "g" => :grass
      tiles :house, "f" => :floor
      tiles :signs, "s" => :board
      walking = lambda do
        background :ground, tiles: { field: :field, house: :house },
                            map: { field: { meadow: [" " * 30, " " * 30, "g" * 30] },
                                   house: { hall: [" " * 30, " " * 30, "f" * 30] } }
      end
      staying = -> { background :sign, tiles: :signs, map: ["s s"] }
      ground = walking.call if walking_first
      staying.call
      ground ||= walking.call
      pass = var :pass, 0
      room = var :room, 0
      game_loop do
        pass += 1
        room = 1 if pass == WALKS_OUT
        room = 0 if pass == WALKS_BACK
        ground.show_map room
      end
    end
    builder.finalize_program
    builder.program
  end

  SOLID = ["########"] * 8
  SAME_PIXELS = { grass: SOLID, floor: SOLID, board: SOLID }.freeze
  OWN_PIXELS = { grass: ["##......"] * 8, floor: ["....####"] * 8, board: SOLID }.freeze

  def test_a_walking_background_declared_first_agrees_round_the_walks
    assert_backends_agree(walking_game(walking_first: true, pictures: SAME_PIXELS), frames: ROUND_THE_WALKS)
  end

  def test_a_walking_background_declared_after_one_that_stays_agrees_round_the_walks
    assert_backends_agree(walking_game(walking_first: false, pictures: SAME_PIXELS), frames: ROUND_THE_WALKS)
  end

  def test_a_walking_background_of_its_own_pixels_agrees_in_both_orders
    [true, false].each do |walking_first|
      assert_backends_agree(walking_game(walking_first: walking_first, pictures: OWN_PIXELS), frames: ROUND_THE_WALKS)
    end
  end

  # The console's own pixels after the walk, so the two cannot agree on a blank screen: the sign
  # that stays, and the house's floor under it.
  def test_the_console_shows_the_sign_and_the_house_after_the_walk
    rom = assemble_rom(walking_game(walking_first: false, pictures: SAME_PIXELS), name: "WALKORD")
    v = assert_emulator_loads_rom(rom, frames: WALKS_OUT + 3)

    assert_equal [Color.resolve(:white), Color.resolve(:red)], [v.pixel_gba(4, 4), v.pixel_gba(4, 20)]
  end
end
