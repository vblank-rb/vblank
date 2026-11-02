# frozen_string_literal: true

require "test_helper"
require "scene_color_lists"

# EACH SCREEN'S COLOURS ARE ITS OWN TO COUNT. A Super Nintendo holds eight sets of fifteen colours
# for its backgrounds, and its own games load a screen's sets as they load the screen, so a game
# has dozens across its screens and never more than eight at once.
class TestSceneColorsOnTheSuperNintendo < Minitest::Test
  include SceneColorLists

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  SWITCH_AT = 4

  # Two scenes of eight lists of their own each. +dim+ is how far the screen is faded across the
  # second scene's arrival, toward +toward+. +dusk+, a list of colours, is one the first scene's first
  # list is drawn with from the first frame, said once.
  private def two_scenes(dim: 0, toward: :black, dusk: nil)
    switch = SWITCH_AT
    program do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...8).to_a)
      SceneColorLists.declare(self, :two_set, (8...16).to_a)
      colors :dusk, dusk if dusk
      state = var :state, 0
      tick = var :tick, 0
      faded = var :faded, 0
      scene(:one) do
        first = background :one, tiles: :one_set, map: Array.new(4) { row }
        first.draw_with({ one_set_list0: :dusk }) if dusk && tick == 1
      end
      scene(:two) { background :two, tiles: :two_set, map: Array.new(4) { row } }
      game_loop do
        tick += 1
        faded = dim if tick == switch - 1
        faded = 0 if tick == switch + 3
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        fade toward, faded
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  private def shown_by(prog, frames) = game_player.run(prog, frames: frames).screen

  def test_two_scenes_of_eight_lists_each_show_their_own_colours
    prog = two_scenes

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the first scene's first list"
    assert_equal first_color(7), shown_by(prog, 2).pixel(56, 0), "the first scene's last list"
    assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 0), "the second scene's first"
    assert_equal first_color(15), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(56, 0), "the second scene's last"
    assert_equal first_color(0), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's again"
  end

  # A fade in force as a scene arrives moves the colours that arrive, by the display's brightness
  # toward black, and by walking the colours toward white.
  def test_the_colours_of_a_scene_arriving_under_a_fade_arrive_faded
    %i[black white].each do |toward|
      prog = two_scenes(dim: 50, toward: toward)

      refute_equal first_color(8), shown_by(prog, SWITCH_AT + 2).pixel(0, 0), toward
      assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 0), "whole once the fade is over"
    end
  end

  # A background drawn with another list keeps it when its scene comes back, said once, though the
  # scene's own colours came in again with it.
  def test_a_scene_back_keeps_the_list_its_background_was_drawn_with
    dusk = full_list(20)
    prog = two_scenes(dusk: dusk)

    assert_equal dusk[1], shown_by(prog, 3).pixel(0, 0), "drawn with the other list"
    assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 0), "the second scene"
    assert_equal dusk[1], shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "and back"
  end

  # Two scenes declare one name, and only the second draws it with other colours: the first's own
  # background has no lists to say again as it arrives.
  def test_a_name_two_scenes_declare_and_one_recolours_shows_both
    dusk = full_list(20)
    switch = SWITCH_AT
    prog = program do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...8).to_a)
      SceneColorLists.declare(self, :two_set, (8...16).to_a)
      colors :dusk, dusk
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :world, tiles: :one_set, map: Array.new(4) { row } }
      scene(:two) do
        world = background :world, tiles: :two_set, map: Array.new(4) { row }
        world.draw_with({ two_set_list8: :dusk }) if tick == switch + 2
      end
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

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the first scene's"
    assert_equal dusk[1], shown_by(prog, (SWITCH_AT * 2) + 2).pixel(0, 0), "the second's, recoloured"
    assert_equal first_color(0), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's again"
  end

  # What every screen shows keeps its colours on both scenes, whose own take what is left.
  def test_a_background_every_screen_shows_keeps_its_colours_across_scenes
    switch = SWITCH_AT
    prog = program do
      screen :tiled
      always = SceneColorLists.declare(self, :always_set, [0, 1])
      row = SceneColorLists.declare(self, :one_set, (2...8).to_a)
      SceneColorLists.declare(self, :two_set, (8...14).to_a)
      background :always, tiles: :always_set, map: ["#{always}#{' ' * 4}"] * 2
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: [" " * 6, " " * 6, row] }
      scene(:two) { background :two, tiles: :two_set, map: [" " * 6, " " * 6, row] }
      game_loop do
        tick += 1
        state = 1 if tick == switch
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    first = shown_by(prog, 2)
    second = shown_by(prog, (SWITCH_AT * 2) + 1)

    assert_equal first_color(1), first.pixel(8, 0), "every screen's, on the first scene"
    assert_equal first_color(2), first.pixel(0, 16), "the first scene's own"
    assert_equal first_color(1), second.pixel(8, 0), "every screen's, on the second"
    assert_equal first_color(8), second.pixel(0, 16), "the second scene's own"
  end

  # Tiles a scene paints from a list take a set of that scene's: each of these has seven of drawn
  # tiles and one painted, so a painted one kept by every screen would leave neither room.
  def test_tiles_a_scene_paints_from_a_list_take_a_set_of_its_own
    switch = SWITCH_AT
    prog = program do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...7).to_a)
      SceneColorLists.declare(self, :two_set, (7...14).to_a)
      colors :ink_one, SceneColorLists.full_list(14)
      colors :ink_two, SceneColorLists.full_list(15)
      canvas_one = list :canvas_one, capacity: 32, width: :byte
      canvas_two = list :canvas_two, capacity: 32, width: :byte
      repeat(32) do
        canvas_one.push 0x11
        canvas_two.push 0x11
      end
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        tiles :box_one, from: canvas_one, count: 1, colors: :ink_one
        background :painted_one, tiles: :box_one, map: [[1]]
        background :one, tiles: :one_set, map: [" " * 7, row]
      end
      scene(:two) do
        tiles :box_two, from: canvas_two, count: 1, colors: :ink_two
        background :painted_two, tiles: :box_two, map: [[1]]
        background :two, tiles: :two_set, map: [" " * 7, row]
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

    first = shown_by(prog, 3)
    second = shown_by(prog, (SWITCH_AT * 2) + 1)

    assert_equal first_color(14), first.pixel(0, 0), "the first scene's painted tile"
    assert_equal first_color(0), first.pixel(0, 8), "the first scene's drawn tile"
    assert_equal first_color(15), second.pixel(0, 0), "the second scene's painted tile"
    assert_equal first_color(7), second.pixel(0, 8), "the second scene's drawn tile"
  end

  # Tiles in what every screen shows that nothing puts on a map take no set from the scenes.
  def test_tiles_every_screen_never_shows_take_no_colours_from_the_scenes
    switch = SWITCH_AT
    prog = program do
      screen :tiled
      always = SceneColorLists.declare(self, :always_set, (0...9).to_a)
      row = SceneColorLists.declare(self, :one_set, (9...14).to_a)
      SceneColorLists.declare(self, :two_set, (14...19).to_a)
      background :always, tiles: :always_set, map: [always[0, 1] + " " * 4]
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: [" " * 5, row] }
      scene(:two) { background :two, tiles: :two_set, map: [" " * 5, row] }
      game_loop do
        tick += 1
        state = 1 if tick == switch
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "every screen's"
    assert_equal first_color(14), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 8), "the second scene's own"
  end
end
