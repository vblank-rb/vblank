# frozen_string_literal: true

# A SPRITE THAT CHANGES WHICH LAYER IT IS IN, drawn: the games and tests every console that shows two
# backgrounds at once plays (the Advance's in test/console/gba/vblank/dsl/, DOS's in test/console/dos/vblank/dsl/).
# A Game Boy Color shows one background at a time, so these are not in test/all/.
#
# The room is two backgrounds: a white floor at the back and a blue arch in front of it, the arch
# covering the left half of the screen and see-through over the right. The hero is red, and stands
# across the arch's edge, so one pixel of him is under the arch and one is over bare floor. Where he
# is drawn at each of the three depths a room like this has is the whole test:
#
#   * upstairs, in front of both, he is red at both pixels;
#   * on the ground floor, between the two, the arch covers him and the floor does not;
#   * on the stairs, behind both, he shows nowhere, since the floor is solid.
module SpriteLayerChoiceTests
  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  UNDER_ARCH = [100, 66].freeze
  OVER_FLOOR = [108, 66].freeze

  UPPER = 0
  WALKING = 1
  STAIRS = 2

  # The hero's two pixels, under the arch and over bare floor, after a few frames.
  private def pixels(prog)
    screen = game_player.run(prog, max_steps: 400_000, frames: 3).screen
    [screen.pixel(*UNDER_ARCH), screen.pixel(*OVER_FLOOR)]
  end

  private def program(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def room(floor)
    program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :stairs, :ground, :walking, :scenery, :upper

      layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
      layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
      hero = layer(:upper) { sprite :guy, at: [96, 64] }
      depth = var :floor, floor
      game_loop { hero.put_in_layer %i[upper walking stairs], showing: depth }
    end
  end

  def test_upstairs_the_hero_is_in_front_of_both_layers
    assert_equal [RED, RED], pixels(room(UPPER))
  end

  def test_on_the_ground_floor_the_arch_covers_the_hero
    assert_equal [BLUE, RED], pixels(room(WALKING))
  end

  def test_on_the_stairs_the_hero_is_behind_both_layers
    assert_equal [BLUE, WHITE], pixels(room(STAIRS))
  end

  def test_a_number_past_the_list_keeps_the_layer_the_hero_was_declared_in
    assert_equal [RED, RED], pixels(room(7))
  end
end
