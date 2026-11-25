# frozen_string_literal: true

require "test_helper"
require "differential"

# A sprite the game moves with `put_in_layer` is blended (see-through) and held to a placed fade by
# the layer it is in now (layers.md: "a sprite that changes which layer it is in while the game
# runs"), on every run that plays games as the Advance: the interpreter's picture is held to the
# page's own words, and each other build of the game is held to the interpreter on every frame
# (`assert_backends_agree`: on the gba run the cartridge read back in the emulator, on the native,
# JavaScript and Ruby runs the game as C, JavaScript and Ruby). The colours are named: white over
# red half way is what the console was measured to give (test_layer_transparency.rb).
class TestLayerChangeBlendOnTheAdvance < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)
  BLACK = 0
  HALF_WHITE_OVER_RED = 0x3DFF
  CHANGES_AT = 3
  HERO_PIXEL = [66, 66].freeze

  # Frames compared with the other builds: before the change, the pass it is told on and the
  # frames after, where a sprite's picture lags its variables by a frame.
  COMPARED_FRAMES = [2, CHANGES_AT, CHANGES_AT + 1, CHANGES_AT + 2, CHANGES_AT + 4].freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red floor, and a white sprite declared in the layer +declared+ of :solid and :glass (see-through
  # by half) that the game puts into +moved_to+ on its third pass. +keeper+, a sprite declared in
  # :glass for good, or none, so that the moving sprite is all the layer ever holds.
  private def moving_sprite(declared:, moved_to:, keeper: true)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:ghost, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :backset, "#" => :back
      layers :deep, :solid, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:glass, transparency: 50) { sprite :ghost, at: [200, 140] if keeper }
      hero = layer(declared) { sprite :ghost, at: [64, 64] }
      pass = var :pass, 0
      game_loop do
        pass += 1
        hero.put_in_layer moved_to if pass == CHANGES_AT
      end
    end
  end

  # A fade placed in the stack (`fade ... under:`) reaches what is behind its layer and leaves its layer
  # and everything in front alone. A sprite that changes layer follows it across the line.
  private def moving_sprite_under_a_fade(declared:, moved_to:)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:ghost, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :backset, "#" => :back
      layers :deep, :behind, :ahead
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:ahead) { sprite :ghost, at: [200, 140] }
      hero = layer(declared) { sprite :ghost, at: [64, 64] }
      pass = var :pass, 0
      game_loop do
        pass += 1
        hero.put_in_layer moved_to if pass == CHANGES_AT
        fade :black, 100, under: :ahead
      end
    end
  end

  private def pixel_under_hero(program, frames)
    game_player.run(program, frames: frames).screen.pixel(*HERO_PIXEL)
  end

  private def assert_other_builds_agree(program, name)
    assert_backends_agree(program, frames: COMPARED_FRAMES, name: name)
  end

  def test_a_sprite_put_into_a_see_through_layer_is_see_through
    program = moving_sprite(declared: :solid, moved_to: :glass)

    assert_equal WHITE, pixel_under_hero(program, 2), "solid in the layer it was declared in"
    assert_equal HALF_WHITE_OVER_RED, pixel_under_hero(program, CHANGES_AT + 3), "blended with the floor in the layer it is in now"
    assert_other_builds_agree(program, "INGLASS")
  end

  def test_a_sprite_put_into_an_empty_see_through_layer_is_see_through
    program = moving_sprite(declared: :solid, moved_to: :glass, keeper: false)

    assert_equal WHITE, pixel_under_hero(program, 2), "solid in the layer it was declared in"
    assert_equal HALF_WHITE_OVER_RED, pixel_under_hero(program, CHANGES_AT + 3), "blended with the floor in the layer it is in now"
    assert_other_builds_agree(program, "INEMPTY")
  end

  def test_a_sprite_put_out_of_a_see_through_layer_is_solid
    program = moving_sprite(declared: :glass, moved_to: :solid)

    assert_equal HALF_WHITE_OVER_RED, pixel_under_hero(program, 2), "blended in the layer it was declared in"
    assert_equal WHITE, pixel_under_hero(program, CHANGES_AT + 3), "solid in the layer it is in now"
    assert_other_builds_agree(program, "OUTGLASS")
  end

  def test_a_sprite_moved_in_front_of_a_placed_fades_line_is_left_alone_by_it
    program = moving_sprite_under_a_fade(declared: :behind, moved_to: :ahead)

    assert_equal BLACK, pixel_under_hero(program, 2), "behind the line it is faded with the floor"
    assert_equal WHITE, pixel_under_hero(program, CHANGES_AT + 3), "in front of the line it is not"
    assert_other_builds_agree(program, "TOFRONT")
  end

  def test_a_sprite_moved_behind_a_placed_fades_line_is_faded_by_it
    program = moving_sprite_under_a_fade(declared: :ahead, moved_to: :behind)

    assert_equal WHITE, pixel_under_hero(program, 2), "in front of the line it is not faded"
    assert_equal BLACK, pixel_under_hero(program, CHANGES_AT + 3), "behind the line it is faded with the floor"
    assert_other_builds_agree(program, "TOBACK")
  end
end
