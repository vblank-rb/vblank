# frozen_string_literal: true

require "test_helper"
require "stringio"

# A SCENE'S COLOURS ARRIVE WITH ITS MAPS, read off the cartridge a frame at a time. A pass is
# checked against the interpreter whatever the screen did between two of them, so what no frame may
# show has to be asked here: one screen's cells in another's colours, on a screen that stays lit.
class TestSNESSceneColors < Minitest::Test
  LISTS = 8
  SWITCH_AT = 30
  BEFORE = 24
  SETTLED = 40

  private def full_list(n)
    [:transparent, *(1..15).map { |place| VBlank::Graphics::Color.rgb(n, place * 2, 31 - place) }]
  end

  private def declare_lists(builder, prefix, numbers)
    numbers.each do |n|
      builder.colors(:"#{prefix}_list#{n}", full_list(n))
      builder.image(:"#{prefix}_tile#{n}", width: 8, height: 8, colors: :"#{prefix}_list#{n}",
                                           places: Array.new(64) { |i| 1 + (i % 15) })
    end
    builder.tiles(prefix, numbers.each_with_index.to_h { |n, at| [(at + 97).chr, :"#{prefix}_tile#{n}"] })
  end

  # Two scenes of eight lists of their own, whose maps cover the screen, in another order in each,
  # so a map in the other's colours is no picture of either.
  private def rom
    test = self
    switch = SWITCH_AT
    row = ("a".."h").to_a.join * 4
    VBlank.build("SCNCOLORS", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      test.declare_lists(self, :one_set, (0...LISTS).to_a)
      test.declare_lists(self, :two_set, (LISTS...(LISTS * 2)).to_a)
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
  public :declare_lists

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
    test = self
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("NINE", console: :snes, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        test.declare_lists(self, :one_set, (0...9).to_a)
        scene(:crowded) { background :crowded, tiles: :one_set, map: [("a".."i").to_a.join] }
        state = var :state, 0
        game_loop do
          case_var(:state) { when_val 0, :crowded }
        end
      end
    end

    assert_match(/scene :crowded/, error.message)
    assert_match(/fewer colours/, error.message)
  end
end
