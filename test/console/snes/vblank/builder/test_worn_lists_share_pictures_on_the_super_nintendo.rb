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
