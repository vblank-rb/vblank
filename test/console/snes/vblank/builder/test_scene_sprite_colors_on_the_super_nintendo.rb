# frozen_string_literal: true

require "test_helper"
require "scene_color_lists"

# Each screen's sprite colours are its own to count. A Super Nintendo holds eight sets of fifteen
# colours for its sprites, and its own games load a screen's sets with the screen, so two screens
# of eight sets each never meet, the ones the display mixes included.
class TestSceneSpriteColorsOnTheSuperNintendo < Minitest::Test
  include SceneColorLists

  SWITCH_AT = 4
  LEADER = 7 # The list the stage and the demo share
  WALKER_LIST = 20 # The walker's own colours
  PLAYER_LISTS = [21, 22, 23].freeze # The lists the demo's other players are drawn with
  MANY_PLAYER_LISTS = (21..27).to_a.freeze # The same, players enough to fill the sprites' tiles
  LEADER_LIST = 28 # A list the stage's walker and the demo's first player share

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
        call({ 0 => :one, 1 => :two }, number: :state)
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
        call({ 0 => :one, 1 => :two }, number: :state)
      end
    end

    assert_equal first_color(20), shown_by(prog, 3).pixel(56, 0), "the list as it starts"
    assert_equal first_color(15), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(56, 0), "the other screen's list in its set"
    assert_equal first_color(22), shown_by(prog, (SWITCH_AT * 3) + 3).pixel(56, 0), "what it was told while away"
  end

  # A list the game changes that two of three screens draw with keeps its set on those two alone.
  # Every sprite is the pose :walker in a list of its own, as players in their own colours are, and
  # each screen fills all eight sets: the pose's own colours, then seven changing lists. The title
  # has seven of its own; the stage and the demo share the leader's list and have six each. Kept
  # for every screen, the leader's list would make the title nine.
  def test_a_changing_list_two_of_three_scenes_draw_with_counts_on_those_two
    prog = leader_on_two_of_three_scenes

    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the title's first list"
    assert_equal first_color(6), shown_by(prog, 2).pixel(48, 0), "the title's last list"
    assert_equal dusk_color(0), shown_by(prog, 6).pixel(0, 0), "the title's first list changed"
    assert_equal dusk_color(6), shown_by(prog, 6).pixel(48, 0), "the title's last list changed"
    assert_equal dusk_color(LEADER), shown_by(prog, 10).pixel(0, 0), "the leader as told while the title was up"
    assert_equal first_color(13), shown_by(prog, 10).pixel(48, 0), "the stage's last list"
    assert_equal dusk_color(13), shown_by(prog, 14).pixel(48, 0), "the stage's last list changed"
    assert_equal dusk_color(LEADER), shown_by(prog, 18).pixel(0, 0), "the leader as the stage left it, on the demo"
    assert_equal first_color(19), shown_by(prog, 18).pixel(48, 0), "the demo's last list"
    assert_equal dusk_color(19), shown_by(prog, 22).pixel(48, 0), "the demo's last list changed"
    assert_equal dusk_color(LEADER), shown_by(prog, 26).pixel(0, 0), "the leader on the stage again"
    assert_equal dusk_color(13), shown_by(prog, 26).pixel(48, 0), "the stage's own again, changed"
  end

  # The colour list +n+ is changed to: list 20 to 31, round again.
  private def dusk_color(n) = first_color(20 + (n % 12))

  # Three scenes of sprites of the pose :walker, each drawn with a changing list: the title's lists
  # 0 to 6, the stage's the leader's (LEADER) and 8 to 13, the demo's the leader's and 14 to 19. The
  # title is up from the start, the stage from tick 8, the demo from 16, the stage again from 24;
  # each changes its own lists four ticks after it arrives, and the title the leader's, which no
  # sprite of the title draws with.
  private def leader_on_two_of_three_scenes
    leader = LEADER
    program do
      screen :tiled
      colors :walker_list, [:transparent, *(1..15).map { |place| Color.rgb(place * 2, 0, 0) }]
      image(:walker, width: 8, height: 8, colors: :walker_list, places: Array.new(64) { |i| 1 + (i % 15) })
      (0...20).each do |n|
        colors :"walk#{n}", SceneColorLists.full_list(n)
        colors :"dusk#{n}", SceneColorLists.full_list(20 + (n % 12))
      end
      state = var :state, 0
      tick = var :tick, 0
      row = lambda do |lists|
        lists.each_with_index do |n, at|
          walker = sprite :walker, at: [at * 8, 0]
          walker.draw_with :"walk#{n}"
        end
      end
      title = (0..6).to_a
      stage = [leader, *8..13]
      demo = [leader, *14..19]
      scene(:title) { row.call(title) }
      scene(:stage) { row.call(stage) }
      scene(:demo) { row.call(demo) }
      game_loop do
        tick += 1
        state = 1 if tick == 8
        state = 2 if tick == 16
        state = 1 if tick == 24
        [*title, leader].each { |n| recolor :"walk#{n}", :"dusk#{n}" } if tick == 4
        stage.drop(1).each { |n| recolor :"walk#{n}", :"dusk#{n}" } if tick == 12
        demo.drop(1).each { |n| recolor :"walk#{n}", :"dusk#{n}" } if tick == 20
        call({ 0 => :title, 1 => :stage, 2 => :demo }, number: :state)
      end
    end
  end

  # A pose two of three screens show keeps its own colours on those two alone. The title fills its
  # eight sets: five pictures of a list each, a craft picture's own list, and the two lists the
  # game changes that its two craft are drawn with. The stage shows the pose :walker in its own
  # colours, and the demo four players of it: one in its own colours and three drawn with lists of
  # their own. Kept for every screen, the pose's colours would make the title nine.
  def test_a_pose_two_of_three_scenes_show_keeps_its_colors_on_those_two
    prog = pose_on_two_of_three_scenes(PLAYER_LISTS)

    assert_title_and_players(prog, PLAYER_LISTS)
  end

  # The same with seven players walking in five poses of 32×32, each list drawing them in tiles of
  # its own, so that a copy of the poses for each list does not fit the sprites' tiles and the
  # build keeps one set of them for every list (+one_sprite_tile_set+).
  def test_a_pose_two_of_three_scenes_show_in_one_tile_set_keeps_its_colors_on_those_two
    prog = pose_on_two_of_three_scenes(MANY_PLAYER_LISTS, poses: 5, size: 32)

    assert_title_and_players(prog, MANY_PLAYER_LISTS)
  end

  # Where the demo's player +n+ stands, the first being 0: three to a row, 80 pixels apart, rows
  # 64 apart, so that no two overlap.
  def self.player_spot(n) = [(n % 3) * 80, (n / 3) * 64]

  # The list of colours the +at+th player drawn with another list wears, from list +n+: its first
  # 15 - +at+ colours, round again, so that each player's poses are tiles of its own.
  def self.player_list(n, at)
    own = SceneColorLists.full_list(n).drop(1).take(15 - at)
    [:transparent, *(0...15).map { |place| own[place % own.length] }]
  end

  private def player_spot(n) = self.class.player_spot(n)

  # The same with the stage's walker and the demo's first player both drawn with a list that does
  # not change: that copy of the pose takes its set on those two screens alone too.
  def test_a_copy_two_of_three_scenes_draw_with_keeps_its_colors_on_those_two
    prog = pose_on_two_of_three_scenes(PLAYER_LISTS, leader: LEADER_LIST)

    assert_title_and_players(prog, PLAYER_LISTS, first: LEADER_LIST)
  end

  private def assert_title_and_players(prog, players, first: WALKER_LIST)
    assert_equal first_color(0), shown_by(prog, 2).pixel(0, 0), "the title's first picture"
    assert_equal first_color(4), shown_by(prog, 2).pixel(32, 0), "the title's last picture"
    assert_equal first_color(10), shown_by(prog, 2).pixel(48, 0), "the title's first craft"
    assert_equal first_color(11), shown_by(prog, 2).pixel(56, 0), "the title's second craft"
    assert_equal first_color(12), shown_by(prog, 6).pixel(48, 0), "the first craft changed"
    assert_equal first_color(13), shown_by(prog, 6).pixel(56, 0), "the second craft changed"
    assert_equal first_color(first), shown_by(prog, 10).pixel(0, 0), "the walker on the stage"
    demo = shown_by(prog, 18)
    assert_equal first_color(first), demo.pixel(*player_spot(0)), "the first player on the demo"
    players.each_with_index do |n, at|
      assert_equal first_color(n), demo.pixel(*player_spot(at + 1)), "player #{at + 2} on the demo"
    end
  end

  # The title, up from the start: pictures of lists 0 to 4, and two craft drawn with lists 10 and
  # 11, changed to 12 and 13 at tick 4. The stage, from tick 8: the walker. The demo, from 16: the
  # walker, and one drawn with each of +players+ (#player_list). The walker walks in +poses+ poses
  # of +size+ pixels square, slowly enough to show the first throughout. With +leader+, the walker
  # of the stage and the first of the demo are drawn with that list rather than their own colours.
  private def pose_on_two_of_three_scenes(players, poses: 1, size: 8, leader: nil)
    test = self.class
    walker_list = WALKER_LIST
    program do
      screen :tiled
      title_pictures = (0..4).map { |n| test.declare_picture(self, n) }
      craft = test.declare_picture(self, 9)
      colors :walker_list, SceneColorLists.full_list(walker_list)
      walk = (0...poses).map do |pose|
        image(:"walker#{pose}", width: size, height: size, colors: :walker_list,
                                places: Array.new(size * size) { |i| 1 + (((i * i / 3) + (i * 7) + (pose * 11)) % 15) })
        :"walker#{pose}"
      end
      shows = poses > 1 ? { frames: walk, rate: 60 } : { image: walk.first }
      [10, 11, 12, 13].each { |n| colors :"list#{n}", SceneColorLists.full_list(n) }
      players.each_with_index { |n, at| colors :"list#{n}", test.player_list(n, at) }
      state = var :state, 0
      tick = var :tick, 0
      scene(:title) do
        title_pictures.each_with_index { |name, at| sprite name, at: [at * 8, 0] }
        [10, 11].each_with_index do |n, at|
          ship = sprite :"craft#{at}", image: craft, at: [48 + (at * 8), 0]
          ship.draw_with :"list#{n}"
        end
      end
      colors :"list#{leader}", SceneColorLists.full_list(leader) if leader
      scene(:stage) do
        walker = sprite :stage_walker, at: [0, 0], **shows
        walker.draw_with :"list#{leader}" if leader
      end
      scene(:demo) do
        walker = sprite :demo_walker, at: test.player_spot(0), **shows
        walker.draw_with :"list#{leader}" if leader
        players.each_with_index do |n, at|
          player = sprite :"player#{at}", at: test.player_spot(at + 1), **shows
          player.draw_with :"list#{n}"
        end
      end
      game_loop do
        tick += 1
        state = 1 if tick == 8
        state = 2 if tick == 16
        if tick == 4
          recolor :list10, :list12
          recolor :list11, :list13
        end
        call({ 0 => :title, 1 => :stage, 2 => :demo }, number: :state)
      end
    end
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
        call({ 0 => :one, 1 => :two }, number: :state)
      end
    end

    assert_equal first_color(30), shown_by(prog, 3).pixel(0, 0)
    assert_equal first_color(30), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(0, 0)
    assert_equal first_color(14), shown_by(prog, (SWITCH_AT * 2) + 2).pixel(56, 0)
  end
end
