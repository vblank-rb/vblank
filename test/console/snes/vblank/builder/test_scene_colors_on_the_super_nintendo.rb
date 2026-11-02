# frozen_string_literal: true

require "test_helper"

# EACH SCREEN'S COLOURS ARE ITS OWN TO COUNT. A Super Nintendo holds eight sets of fifteen colours
# for its backgrounds, and its own games load a screen's sets as they load the screen, so a game
# has dozens across its screens and never more than eight at once.
class TestSceneColorsOnTheSuperNintendo < Minitest::Test
  # Fifteen colours and see-through: a list no other list can share a set with, numbered +n+.
  private def full_list(n)
    [:transparent, *(1..15).map { |place| VBlank::Graphics::Color.rgb(n, place * 2, 31 - place) }]
  end

  # The first colour of list +n+, which the top left pixel of its tile shows.
  private def first_color(n) = full_list(n)[1]

  # A tile for each of +lists+, drawn in all fifteen of its colours, named +prefix+ and a number; the
  # tileset is +prefix+. Hands back a row of a map showing each tile once.
  private def declare_full_lists(builder, prefix, lists)
    lists.each_with_index do |list, n|
      builder.colors(:"#{prefix}_list#{n}", list)
      builder.image(:"#{prefix}_tile#{n}", width: 8, height: 8, colors: :"#{prefix}_list#{n}",
                                           places: Array.new(64) { |i| 1 + (i % 15) })
    end
    builder.tiles(prefix, lists.each_index.to_h { |n| [(n + 97).chr, :"#{prefix}_tile#{n}"] })
    lists.each_index.map { |n| (n + 97).chr }.join
  end

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  SWITCH_AT = 4

  # Two scenes of +per_scene+ lists of their own each, the first from the top of the numbers. +dim+
  # is how far the screen is faded across the second scene's arrival. +dusk+, a list of colours,
  # is one the first scene's first list is drawn with from the first frame, said once.
  private def two_scenes(per_scene: 8, dim: 0, dusk: nil)
    test = self
    lists = [(0...per_scene), (per_scene...(per_scene * 2))].map { |numbers| numbers.map { |n| full_list(n) } }
    switch = SWITCH_AT
    program do
      screen :tiled
      row = test.declare_full_lists(self, :one_set, lists[0])
      test.declare_full_lists(self, :two_set, lists[1])
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
        fade :black, faded
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end
  public :declare_full_lists

  private def shown_by(prog, frames) = game_player.run(prog, frames: frames).screen

  def test_two_scenes_of_eight_lists_each_show_their_own_colours
    prog = two_scenes

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the first scene's first list"
    assert_equal first_color(7), shown_by(prog, 2).pixel(56, 0), "the first scene's last list"
    assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 0), "the second scene's first"
    assert_equal first_color(15), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(56, 0), "the second scene's last"
    assert_equal first_color(0), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's again"
  end

  # A fade in force as a scene arrives moves the colours that arrive.
  def test_the_colours_of_a_scene_arriving_under_a_fade_arrive_faded
    prog = two_scenes(dim: 50)

    refute_equal first_color(8), shown_by(prog, SWITCH_AT + 2).pixel(0, 0)
    assert_equal first_color(8), shown_by(prog, (SWITCH_AT * 2) + 1).pixel(0, 0), "and whole once the fade is over"
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

  # What every screen shows keeps its colours on both scenes, whose own take what is left.
  def test_a_background_every_screen_shows_keeps_its_colours_across_scenes
    test = self
    lists = (0...14).map { |n| full_list(n) }
    switch = SWITCH_AT
    prog = program do
      screen :tiled
      always = test.declare_full_lists(self, :always_set, lists[0, 2])
      row = test.declare_full_lists(self, :one_set, lists[2, 6])
      test.declare_full_lists(self, :two_set, lists[8, 6])
      background :always, tiles: :always_set, map: ["#{always}#{' ' * 18}"] * 2
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
end

