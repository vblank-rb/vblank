# frozen_string_literal: true

require "test_helper"

# LOADS OF SPRITE TILES ON THE COLOR (GBC::Lowering::SpriteTiles, Runtime::SpriteTileLoads): a load
# is noted in the pass and copied from the cartridge in the blank after it, and a blank holds the
# copies of a few loads.
class TestGBCSpriteTileLoads < Minitest::Test
  GBC = VBlank::IR::Backends::GBC
  MOST = GBC::Runtime::SpriteTileLoads::MOST_LOADS

  def test_a_pass_loading_more_than_the_blank_holds_stops_the_game_and_says_so
    error = assert_raises(VBlank::IR::ProgramError) do
      GBC::HeadlessRun.new.run(loading_game(MOST + 1), frames: 3)
    end

    assert_includes error.message, "more than #{MOST} times in one pass"
  end

  def test_a_pass_loading_as_many_as_the_blank_holds_agrees_with_the_interpreter
    GBC::CheckedRun.new.run(loading_game(MOST), frames: 3)
    pass
  end

  def test_a_game_that_loads_no_tiles_carries_no_routine_for_them
    code = GBC.new.build(loading_game(0)).built.code

    refute code.key?("rt_sprite_tile_loads")
  end

  private

  # A pose of one tile, and +loads+ loads of it each pass, each from the next tile of the art.
  def loading_game(loads)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :ball, %i[transparent red green white]
      image :art, width: 8, height: 32, colors: :ball, places: (0...4).flat_map { |tile| [tile % 3 + 1] * 64 }
      set = sprite_tiles :ball_tiles, count: 1, colors: :ball
      image :ball, tiles_from: :ball_tiles, pieces: [[0, 0, 0]]
      sprite :ball, at: [40, 40]
      game_loop do
        loads.times { |k| set.copy_from :art, at: k % 4, count: 1, to: 0 }
      end
    end
    b.finalize_program
    b.program
  end
end
