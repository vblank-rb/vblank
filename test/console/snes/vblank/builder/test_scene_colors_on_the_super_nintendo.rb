# frozen_string_literal: true

require "test_helper"
require "scene_color_lists"

# Each screen's colours are its own to count. A Super Nintendo holds eight sets of fifteen colours
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
        call({ 0 => :one, 1 => :two }, number: :state)
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
        call({ 0 => :one, 1 => :two }, number: :state)
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
        call({ 0 => :one, 1 => :two }, number: :state)
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
        call({ 0 => :one, 1 => :two }, number: :state)
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
        call({ 0 => :one, 1 => :two }, number: :state)
      end
    end

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "every screen's"
    assert_equal first_color(14), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 8), "the second scene's own"
  end

  SAND = [10, 6, 4].freeze
  LAMP = [28, 12, 31].freeze
  PANEL = [5, 25, 15].freeze

  # A scene of eight lists of its own, then a scene whose three backgrounds put one on the third
  # layer: an arena, a light that takes the arena away, and a bar held alone above row 32. The
  # third layer's colours are in the backgrounds' first set, and only on the screen that shows it.
  private def full_scene_then_barred_light
    switch = SWITCH_AT
    sand = SAND
    lamp = LAMP
    panel = PANEL
    tile = SOLID_TILE
    program do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...8).to_a)
      image(:sand, "#" => rgb(*sand)) { tile }
      image(:lamp, "#" => rgb(*lamp)) { tile }
      image(:panel, "#" => rgb(*panel)) { tile }
      tiles :sands, "#" => :sand
      tiles :lamps, "#" => :lamp
      tiles :panels, "#" => :panel
      layers :arena, :light, :bar
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: Array.new(4) { row } }
      scene(:two) do
        layer(:arena) { background :floor, tiles: :sands, map: Array.new(32) { "#" * 32 } }
        layer(:light, shows: 100, shows_behind: 100, subtract: true) do
          background :glow, tiles: :lamps, map: Array.new(32) { ("#" * 16) + (" " * 16) }
        end
        layer(:bar) { background :score, tiles: :panels, map: Array.new(4) { "#" * 32 }, above_row: 32, alone: :without_sprites }
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        call({ 0 => :one, 1 => :two }, number: :state)
      end
    end
  end

  private def rgb5(red, green, blue) = red | (green << 5) | (blue << 10)

  # A bar tile in three colours of its own, so each takes a list of the third layer to itself:
  # colour +n+ * 3, and the two after it.
  private def bar_tile_colors(n) = (0...3).map { |i| [n + 1, (n * 3) + i + 4, 31 - i] }

  # Two screens with a bar held alone above row 32, each in tiles of its own colours: the first a
  # bar of two lists over a background of seven lists of fifteen, the second a bar of three lists
  # over an arena and a light that takes it away. Together the two bars need two of the eight sets,
  # and the first screen has only one to spare; alone each needs one. The game opens on the first.
  private def two_barred_screens
    switch = SWITCH_AT
    sand = SAND
    lamp = LAMP
    tile = SOLID_TILE
    bars = (0...5).map { |n| bar_tile_colors(n) }
    striped = ("abcabcab\n" * 8).chomp
    program do
      screen :tiled
      row = SceneColorLists.declare(self, :one_set, (0...7).to_a)
      bars.each_with_index do |(a, b, c), n|
        image(:"bar#{n}", "a" => rgb(*a), "b" => rgb(*b), "c" => rgb(*c)) { striped }
      end
      image(:sand, "#" => rgb(*sand)) { tile }
      image(:lamp, "#" => rgb(*lamp)) { tile }
      tiles :one_bar, "0" => :bar0, "1" => :bar1
      tiles :two_bar, "2" => :bar2, "3" => :bar3, "4" => :bar4
      tiles :sands, "#" => :sand
      tiles :lamps, "#" => :lamp
      layers :arena, :light, :bar
      state = var :state, 0
      tick = var :tick, 0
      below = Array.new(4) { " " * 7 } + Array.new(4) { row }
      scene(:one) do
        background :one, tiles: :one_set, map: below
        layer(:bar) { background :one_score, tiles: :one_bar, map: Array.new(4) { "01" }, above_row: 32, alone: :without_sprites }
      end
      scene(:two) do
        layer(:arena) { background :floor, tiles: :sands, map: Array.new(32) { "#" * 32 } }
        layer(:light, shows: 100, shows_behind: 100, subtract: true) do
          background :glow, tiles: :lamps, map: Array.new(32) { ("#" * 16) + (" " * 16) }
        end
        layer(:bar) { background :two_score, tiles: :two_bar, map: Array.new(4) { "234" }, above_row: 32, alone: :without_sprites }
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        call({ 0 => :one, 1 => :two }, number: :state)
      end
    end
  end

  # Each bar's first colour, read at the left of each of its tiles.
  private def bar_firsts(screen, count) = (0...count).map { |at| screen.pixel(at * 8, 0) }

  private def first_bar_colors(range) = range.map { |n| rgb5(*bar_tile_colors(n).first) }

  def test_two_screens_keep_their_own_bars_lists_beside_seven_lists
    prog = two_barred_screens
    one = shown_by(prog, 2)
    two = shown_by(prog, (SWITCH_AT * 2) + 1)
    back = shown_by(prog, (SWITCH_AT * 3) + 3)

    assert_equal first_bar_colors(0..1), bar_firsts(one, 2), "the first screen's bar, from power-on"
    assert_equal first_color(6), one.pixel(48, 32), "the first screen's last list below its bar"
    assert_equal first_bar_colors(2..4), bar_firsts(two, 3), "the second screen's bar"
    assert_equal rgb5(18, 6, 27), two.pixel(8, 40), "the light below the second bar"
    assert_equal first_bar_colors(0..1), bar_firsts(back, 2), "the first screen's bar again"
    assert_equal first_color(0), back.pixel(0, 32), "the first screen's first list again"
  end

  def test_eight_lists_of_one_scene_beside_a_third_layer_on_another
    prog = full_scene_then_barred_light
    two = shown_by(prog, (SWITCH_AT * 2) + 1)

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the first scene's first list"
    assert_equal first_color(7), shown_by(prog, 2).pixel(56, 0), "the first scene's last list"
    assert_equal rgb5(*PANEL), two.pixel(8, 8), "the bar, in the third layer's colours"
    assert_equal rgb5(18, 6, 27), two.pixel(8, 40), "the light below the bar, the sand taken away"
    assert_equal first_color(0), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's first list again"
  end
end
