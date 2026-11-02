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
  private def dressed_game(which)
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
        dressed = sprite :"picture#{n}", at: [(n % COLUMNS) * SIZE, (n / COLUMNS) * SIZE]
        dressed.draw_with %i[second third], showing: shown
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

  private def corner_color(which, number)
    played = game_player.run(dressed_game(which), frames: 4)
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
