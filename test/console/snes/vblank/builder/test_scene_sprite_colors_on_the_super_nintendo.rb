# frozen_string_literal: true

require "test_helper"
require "scene_color_lists"

# EACH SCREEN'S SPRITE COLOURS ARE ITS OWN TO COUNT. A Super Nintendo holds eight sets of fifteen
# colours for its sprites, and its own games load a screen's sets with the screen, so two screens
# of eight sets each never meet, the ones the display mixes included.
class TestSceneSpriteColorsOnTheSuperNintendo < Minitest::Test
  include SceneColorLists

  SWITCH_AT = 4

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A picture of 8×8 in all fifteen colours of list +n+, and its name.
  def self.declare_picture(builder, n)
    builder.colors(:"sprite_list#{n}", SceneColorLists.full_list(n))
    builder.image(:"sprite_picture#{n}", width: 8, height: 8, colors: :"sprite_list#{n}",
                                         places: Array.new(64) { |i| 1 + (i % 15) })
    :"sprite_picture#{n}"
  end

  # Two scenes, showing a row of sprites of a list each. With +mixed+, each scene's last four are on
  # a see-through layer.
  private def two_scenes(first:, second:, mixed: false)
    switch = SWITCH_AT
    test = self.class
    program do
      screen :tiled
      layers :solid, :glass if mixed
      layer(:glass, transparency: 50) {} if mixed
      if mixed
        image(:ground_art, "#" => :green) { "########\n" * 8 }
        tiles :ground_set, "#" => :ground_art
        layer(:solid) { background :ground, tiles: :ground_set, map: Array.new(32) { "#" * 32 } }
      end
      first_pictures = first.map { |n| test.declare_picture(self, n) }
      second_pictures = second.map { |n| test.declare_picture(self, n) }
      state = var :state, 0
      tick = var :tick, 0
      row = lambda do |pictures|
        pictures.each_with_index do |name, at|
          if mixed && at >= 4
            layer(:glass) { sprite name, at: [at * 8, 0] }
          else
            sprite name, at: [at * 8, 0]
          end
        end
      end
      scene(:one) { row.call(first_pictures) }
      scene(:two) { row.call(second_pictures) }
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  private def shown_by(prog, frames) = game_player.run(prog, frames: frames).screen

  def test_two_scenes_of_many_lists_each_show_their_own_sprite_colors
    prog = two_scenes(first: (0...8).to_a, second: (8...16).to_a)

    assert_equal first_color(0), shown_by(prog, 3).pixel(0, 0), "the first scene's first list"
    assert_equal first_color(7), shown_by(prog, 3).pixel(56, 0), "the first scene's last list"
    assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(0, 0), "the second scene's first"
    assert_equal first_color(15), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(56, 0), "the second scene's last"
    assert_equal first_color(0), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's again"
  end

  # The console mixes the last four sets alone, on either screen.
  def test_each_scene_has_its_own_sets_the_ones_it_mixes_included
    prog = two_scenes(first: (0...8).to_a, second: (8...16).to_a, mixed: true)

    assert_equal first_color(3), shown_by(prog, 3).pixel(24, 0), "the first scene's last solid list"
    assert_equal first_color(11), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(24, 0), "the second scene's"
    refute_equal shown_by(prog, 3).pixel(32, 0), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(32, 0),
                 "the lists it mixes are the scene's own too"
  end

  # A list of colours the game changes keeps a set of its own, on its own screen, and what it was
  # told while another screen was up shows when its screen comes back.
  def test_a_list_a_scene_changes_shows_what_it_was_told_when_the_scene_returns
    switch = SWITCH_AT
    test = self.class
    first = (0...6).to_a
    second = (8...16).to_a
    prog = program do
      screen :tiled
      first_pictures = first.map { |n| test.declare_picture(self, n) }
      second_pictures = second.map { |n| test.declare_picture(self, n) }
      colors :walking, SceneColorLists.full_list(20)
      colors :dusk, SceneColorLists.full_list(22)
      test.declare_picture(self, 21)
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        first_pictures.each_with_index { |name, at| sprite name, at: [at * 8, 0] }
        walker = sprite :sprite_picture21, at: [56, 0]
        walker.draw_with :walking
      end
      scene(:two) { second_pictures.each_with_index { |name, at| sprite name, at: [at * 8, 0] } }
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        recolor :walking, :dusk if tick == switch + 1
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal first_color(20), shown_by(prog, 3).pixel(56, 0), "the list as it starts"
    assert_equal first_color(15), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(56, 0), "the other screen's list in its set"
    assert_equal first_color(22), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(56, 0), "what it was told while away"
  end

  # What is on both screens keeps its set on both.
  def test_a_picture_both_scenes_show_keeps_its_colors_on_both
    switch = SWITCH_AT
    test = self.class
    prog = program do
      screen :tiled
      both = test.declare_picture(self, 30)
      first_pictures = (0...7).map { |n| test.declare_picture(self, n) }
      second_pictures = (8...15).map { |n| test.declare_picture(self, n) }
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        sprite both, at: [0, 0]
        first_pictures.each_with_index { |name, at| sprite name, at: [(at + 1) * 8, 0] }
      end
      scene(:two) do
        sprite both, at: [0, 0]
        second_pictures.each_with_index { |name, at| sprite name, at: [(at + 1) * 8, 0] }
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal first_color(30), shown_by(prog, 3).pixel(0, 0)
    assert_equal first_color(30), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(0, 0)
    assert_equal first_color(14), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(56, 0)
  end
end
