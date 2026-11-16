# frozen_string_literal: true

require "test_helper"
require "stringio"
require "scene_color_lists"

# A SCENE'S COLOURS ARRIVE WITH ITS MAPS, read off the cartridge a frame at a time. A pass is
# checked against the interpreter whatever the screen did between two of them, so what no frame may
# show has to be asked here: one screen's cells in another's colours, on a screen that stays lit.
class TestSNESSceneColors < Minitest::Test
  SWITCH_AT = 30
  BEFORE = 24
  SETTLED = 40

  # Two scenes of eight lists of their own, whose maps cover the screen, in another order in each,
  # so a map in the other's colours is no picture of either.
  private def rom
    switch = SWITCH_AT
    VBlank.build("SCNCOLORS", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...8).to_a) * 4
      SceneColorLists.declare(self, :two_set, (8...16).to_a)
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: Array.new(32) { row } }
      scene(:two) { background :two, tiles: :two_set, map: Array.new(32) { row.reverse } }
      game_loop do
        tick += 1
        state = 1 if tick == switch
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  private def picture_at(built, frames) = VBlank::Diagnostics::Verifier.new(built, frames: frames)

  def test_no_lit_frame_shows_one_scenes_cells_in_the_others_colours
    built = rom
    first = picture_at(built, BEFORE)
    second = picture_at(built, SETTLED)
    refute first.same_picture_as?(second), "the two scenes show different pictures"

    played = picture_at(built, BEFORE)
    (SETTLED - BEFORE).times do |frame|
      played.step

      assert played.same_picture_as?(first) || played.same_picture_as?(second),
             "#{frame + 1} frames on the picture is neither scene's: #{played.difference_from(first)}"
    end
  end

  def test_a_game_that_fits_the_eight_is_built_as_before
    built = VBlank.build("FITS", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :dots, "#" => :dot
      background :field, tiles: :dots, map: ["#" * 32]
      game_loop { wait_vblank }
    end

    refute built.built.code.key?("rt_colors_hold"), "a game of one set of colours keeps no routine for bringing others in"
  end

  def test_a_scene_with_more_than_eight_sets_is_refused_naming_it
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("NINE", console: :snes, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        row = SceneColorLists.declare(self, :one_set, (0...9).to_a)
        scene(:crowded) { background :crowded, tiles: :one_set, map: [row] }
        state = var :state, 0
        game_loop do
          case_var(:state) { when_val 0, :crowded }
        end
      end
    end

    assert_match(/scene :crowded/, error.message)
    assert_match(/fewer colours/, error.message)
  end

  CRAFT_IMAGES = 24

  # A stage whose arena takes all eight sets of background colours and whose bar walks a list of its
  # own up from black, which needs a ninth, beside sprites that fit their tiles only as one set of
  # pictures worn in another list. The sprites are laid out before the bar's walk, so the backgrounds
  # run out only in the build that fits the sprites, and that is what the game is told.
  def test_backgrounds_over_their_sets_beside_worn_sprites_are_refused_naming_the_backgrounds
    places = Array.new(CRAFT_IMAGES) { |n| Random.new(n).then { |rng| Array.new(32 * 32) { rng.rand(2) } } }
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("HELDNINE", console: :snes, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        layers :scenery, :craft, :bar
        arena_row = SceneColorLists.declare(self, :arena, (0...8).to_a)
        bar_row = SceneColorLists.declare(self, :bar, [20])
        colors :hero, %i[transparent white red]
        colors :hurt, %i[transparent yellow blue]
        CRAFT_IMAGES.times { |n| image(:"craft_#{n}", width: 32, height: 32, colors: :hero, places: places.fetch(n)) }
        var :state, 0
        walk = var :walk, 0
        scene(:stage) do
          layer(:scenery) { background :arena, tiles: :arena, map: [arena_row] }
          layer(:craft) { CRAFT_IMAGES.times { |n| sprite(:"craft_#{n}", at: [(n % 6) * 36, 40 + ((n / 6) * 34)]).draw_with :hurt } }
          layer(:bar) do
            bar = background :bar, tiles: :bar, map: [bar_row]
            bar.draw_with({ bar_list20: color_walk(:bar_list20, from: :black) }, showing: walk)
          end
        end
        game_loop do
          walk += 1
          case_var(:state) { when_val 0, :stage }
        end
      end
    end

    assert_match(/backgrounds of the scene :stage hold more lists of colours/, error.message)
  end
end
