# frozen_string_literal: true

require "test_helper"
require "scene_color_lists"

# ONE SET OF SPRITE PICTURES WORN IN SEVERAL LISTS OF COLOURS. A Super Nintendo sprite says which of
# eight lists it is drawn from, so a console game draws all its players from one set of pictures. A
# game whose pictures, made again for each list, would not fit the 512 tiles of sprite memory is built
# that way too.
class TestWornListsSharePicturesOnTheSuperNintendo < Minitest::Test
  include SceneColorLists

  PICTURES = 24
  COLUMNS = 7
  SIZE = 32
  # A flash: two colours turn about, so a copy of a picture in it, drawn from a list of those two,
  # shares none of its tiles with the picture.
  FLASH = [:transparent, *Array.new(15) { |place| VBlank::Graphics::Color.rgb(31, 31, place.odd? ? 31 : 0) }].freeze

  private def list_of(number) = SceneColorLists.full_list(number)

  private def places_of(number)
    rng = Random.new(number)
    Array.new(SIZE * SIZE) { rng.rand(1..15) }
  end

  # PICTURES pictures of all different tiles, each on a sprite of its own, and each sprite drawn in
  # its own colours, then in each of two other lists as +which+ moves. Three copies of each would be
  # three times 16 tiles a picture, far past the 512.
  private def game_of_two_lists(which)
    pictures = PICTURES.times.map { |n| places_of(n) }
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :first_list, SceneColorLists.full_list(1)
      colors :second, SceneColorLists.full_list(2)
      colors :third, FLASH
      shown = var :shown, which
      pictures.each_with_index do |places, n|
        image :"picture#{n}", width: SIZE, height: SIZE, colors: :first_list, places: places
        listed = sprite :"picture#{n}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE]
        listed.draw_with %i[second third], showing: shown
      end
      game_loop { nil }
    end
    b.finalize_program
    b.program
  end

  # Two sprites of one picture, in a scene: the same picture worn by each in a list of its own.
  private def two_players_game
    pictures = PICTURES.times.map { |n| places_of(n) }
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :first_list, SceneColorLists.full_list(1)
      colors :second, SceneColorLists.full_list(2)
      colors :third, FLASH
      pictures.each_with_index { |places, n| image :"picture#{n}", width: SIZE, height: SIZE, colors: :first_list, places: places }
      faces = PICTURES.times.map { |n| :"picture#{n}" }
      scene(:stage) do
        one = sprite :one, frames: faces, rate: 60, at: [0, 0]
        two = sprite :two, frames: faces, rate: 60, at: [64, 0]
        one.draw_with :second
        two.draw_with :third
      end
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :stage } }
    end
    b.finalize_program
    b.program
  end

  def test_two_sprites_wear_one_set_of_pictures_in_a_scene
    played = game_player.run(two_players_game, frames: 4)
    place = places_of(0).first

    assert_equal list_of(2)[place], played.screen.pixel(0, 0)
    assert_equal FLASH[place], played.screen.pixel(64, 0)
  end

  # A picture given as colours, black among them, in every list of the game above. The list's
  # see-through first place is held as black too, and must not swallow it.
  private def black_picture_game
    pictures = PICTURES.times.map { |n| places_of(n) }
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled, backdrop: :blue
      colors :first_list, SceneColorLists.full_list(1)
      colors :second, SceneColorLists.full_list(2)
      colors :third, FLASH
      colors :shape, %i[transparent white black]
      colors :shape_flash, %i[transparent red black]
      shown = var :shown, 0
      pictures.each_with_index do |places, n|
        image :"picture#{n}", width: SIZE, height: SIZE, colors: :first_list, places: places
        listed = sprite :"picture#{n}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE]
        listed.draw_with %i[second third], showing: shown
      end
      image(:shape_picture, "." => :white, "#" => :black, colors: :shape) { (["#.#.#.#."] * 8).join("\n") }
      shape = sprite :shape_picture, at: [0, 128]
      shape.draw_with :shape_flash
      game_loop { nil }
    end
    b.finalize_program
    b.program
  end

  def test_black_stays_drawn_in_a_picture_given_as_colors
    played = game_player.run(black_picture_game, frames: 4)

    assert_equal VBlank::Graphics::Color.rgb(0, 0, 0), played.screen.pixel(0, 128)
    assert_equal VBlank::Graphics::Color.rgb(31, 0, 0), played.screen.pixel(1, 128)
  end

  # One small sprite wearing each of seven lists of a colour each, which fit one set of colours but
  # take seven kept in their places, and big pictures each scene shows alone. Sharing tiles cannot fit
  # that, and each scene keeping its own tiles can.
  private def game_whose_lists_do_not_fit_in_places(last_list_recolored:)
    pictures = (PICTURES * 2).times.map { |n| places_of(n) }
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :first_list, SceneColorLists.full_list(1)
      colors :small_list, [:transparent, VBlank::Graphics::Color.rgb(31, 0, 0)]
      lists = (1..7).map do |n|
        colors :"list#{n}", [:transparent, VBlank::Graphics::Color.rgb(n, 31, 0)]
        :"list#{n}"
      end
      pictures.each_with_index { |places, n| image :"picture#{n}", width: SIZE, height: SIZE, colors: :first_list, places: places }
      image :small, width: 8, height: 8, colors: :small_list, places: [1] * 64
      small = sprite :small, at: [232, 152]
      small.draw_with lists, showing: 0
      recolor :list7, :list6 if last_list_recolored
      scene(:one) { PICTURES.times { |n| sprite :"picture#{n}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE] } }
      scene(:two) { PICTURES.times { |n| sprite :"picture#{n + PICTURES}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE] } }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :one; when_val 1, :two } }
    end
    b.finalize_program
    b.program
  end

  def test_lists_that_do_not_fit_in_places_build_the_way_they_did
    [false, true].each do |recolored|
      played = game_player.run(game_whose_lists_do_not_fit_in_places(last_list_recolored: recolored), frames: 4)

      assert_equal VBlank::Graphics::Color.rgb(1, 31, 0), played.screen.pixel(232, 152), "recolored: #{recolored}"
    end
  end

  # A list two scenes wear on pictures of their own, in a game whose scenes each bring their own
  # colours in: it has one number in each scene.
  private def scenes_sharing_a_list_game
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :shield, FLASH
      (1..13).each { |n| colors :"own#{n}", SceneColorLists.full_list(n) }
      pictures = Array.new(PICTURES * 2) { |n| places_of_picture = Random.new(n); Array.new(SIZE * SIZE) { places_of_picture.rand(1..15) } }
      pictures.each_with_index { |places, n| image :"picture#{n}", width: SIZE, height: SIZE, colors: :own1, places: places }
      solid = (2..13).map do |n|
        image :"solid#{n}", width: 8, height: 8, colors: :"own#{n}", places: Array.new(64) { |i| 1 + (i % 15) }
        :"solid#{n}"
      end
      scene(:one) do
        PICTURES.times do |n|
          worn = sprite :"picture#{n}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE]
          worn.draw_with :shield
        end
        solid.first(6).each_with_index { |name, at| sprite name, at: [at * 8, 152] }
      end
      scene(:two) do
        PICTURES.times do |n|
          worn = sprite :"picture#{n + PICTURES}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE]
          worn.draw_with :shield
        end
        solid.last(6).each_with_index { |name, at| sprite name, at: [at * 8, 152] }
      end
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :one; when_val 1, :two } }
    end
    b.finalize_program
    b.program
  end

  def test_a_list_worn_in_two_scenes_shows_its_colors
    played = game_player.run(scenes_sharing_a_list_game, frames: 4)

    assert_equal FLASH[Random.new(0).rand(1..15)], played.screen.pixel(0, 0)
  end

  WALK_POSES = 40
  DEATH_POSES = 8
  ENEMY_POSES = 16
  POSE_SIZE = 16

  # A stage of two heroes of one walk, worn in their own lists and a shield's, their deaths in theirs,
  # a sign and an enemy each in a list of its own: five lists of sprite colours on one screen. A copy
  # of each pose per list is past the 512 tiles; one set of them fits. The title before it has a
  # see-through sprite, which the console's colour math reaches only through the last four sets of
  # sprite colours, while the stage, where the math is off, can draw from all eight.
  private def stage_of_five_lists_game(shown)
    poses = ->(prefix, count, list, seed) do
      Array.new(count) do |n|
        image :"#{prefix}#{n}", width: POSE_SIZE, height: POSE_SIZE, colors: list,
                                places: Random.new(seed + n).then { |rng| Array.new(POSE_SIZE * POSE_SIZE) { rng.rand(1..15) } }
        :"#{prefix}#{n}"
      end
    end
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      layers :ghosts
      (1..6).each { |n| colors :"list#{n}", SceneColorLists.full_list(n) }
      walk = instance_exec(:walk, WALK_POSES, :list1, 0, &poses)
      death = instance_exec(:death, DEATH_POSES, :list1, 100, &poses)
      enemy = instance_exec(:enemy, ENEMY_POSES, :list5, 200, &poses)
      sign = instance_exec(:sign, 1, :list4, 300, &poses).first
      instance_exec(:ghost, 1, :list6, 400, &poses)
      worn = var :worn, shown
      scene(:title) { layer(:ghosts, shows: 100, shows_behind: 100) { sprite :ghost0, at: [0, 0] } }
      scene(:stage) do
        one = sprite :one, frames: walk, rate: 60, at: [0, 0]
        one.draw_with %i[list1 list3], showing: worn
        two = sprite :two, frames: walk, rate: 60, at: [32, 0]
        two.draw_with %i[list2 list3], showing: worn
        sprite(:one_dying, frames: death, rate: 60, at: [64, 0]).draw_with :list1
        sprite(:two_dying, frames: death, rate: 60, at: [96, 0]).draw_with :list2
        sprite :enemy, frames: enemy, rate: 60, at: [128, 0]
        sprite(sign, at: [160, 0]).draw_with :list4
      end
      var :state, 1
      game_loop { case_var(:state) { when_val 0, :title; when_val 1, :stage } }
    end
    b.finalize_program
    b.program
  end

  private def first_place(seed) = Random.new(seed).rand(1..15)

  def test_five_lists_on_a_stage_wear_one_set_of_pictures_beside_a_see_through_title
    { 0 => [1, 2], 1 => [3, 3] }.each do |shown, (first_list, second_list)|
      played = game_player.run(stage_of_five_lists_game(shown), frames: 4)

      assert_equal list_of(first_list)[first_place(0)], played.screen.pixel(0, 0), "hero, list #{shown}"
      assert_equal list_of(second_list)[first_place(0)], played.screen.pixel(32, 0), "second hero, list #{shown}"
      assert_equal list_of(2)[first_place(100)], played.screen.pixel(96, 0), "second hero dying"
      assert_equal list_of(5)[first_place(200)], played.screen.pixel(128, 0), "enemy"
      assert_equal list_of(4)[first_place(300)], played.screen.pixel(160, 0), "sign"
    end
  end

  private def corner_color(which, number)
    played = game_player.run(game_of_two_lists(which), frames: 4)
    played.screen.pixel((number % COLUMNS) * SIZE, (number / COLUMNS) * SIZE)
  end

  def test_each_sprite_shows_each_list_from_one_set_of_pictures
    { 0 => list_of(2), 1 => FLASH, 2 => list_of(1) }.each do |which, list|
      [0, PICTURES - 1].each do |number|
        place = places_of(number).first

        assert_equal list[place], corner_color(which, number), "list #{which}, picture #{number}"
      end
    end
  end
end
