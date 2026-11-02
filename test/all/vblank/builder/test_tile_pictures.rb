# frozen_string_literal: true

require "test_helper"
require "differential"

# TILES TAKING TURNS THROUGH PICTURES HELD IN THE CARTRIDGE: flowers and water over a map that does
# not change. One word says which picture a whole group shows.
class TestTilePictures < Minitest::Test
  include Differential

  RED = 0x001F
  BLUE = 0x7C00
  GREEN = 0x03E0

  # A tile of 8×8 all in place +place+ of the list :pond.
  def self.solid(builder, name, place)
    builder.image(name, width: 8, height: 8, colors: :pond, places: Array.new(64, place))
    name
  end

  # A background of two moving tiles and a still one. +step+ says the picture from the pass.
  private def water_game(&step)
    test = self.class
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :pond, %i[transparent red blue green]
      test.solid(self, :red_tile, 1)
      test.solid(self, :blue_tile, 2)
      test.solid(self, :green_tile, 3)
      water = tile_pictures :water, colors: :pond, tiles: { left: %i[red_tile blue_tile green_tile],
                                                            right: %i[blue_tile green_tile red_tile] }
      tiles :field, "l" => water[:left], "r" => water[:right], "#" => :green_tile
      background :ground, tiles: :field, map: ["lr#"]
      tick = var :tick, 0
      game_loop do
        tick += 1
        instance_exec(water, tick, &step)
      end
    end
    b.finalize_program
    b.program
  end

  private def shown(program, frames)
    screen = game_player.run(program, frames: frames).screen
    [screen.pixel(4, 4), screen.pixel(12, 4), screen.pixel(20, 4)]
  end

  def test_the_tiles_show_their_first_pictures_from_the_start
    assert_equal [RED, BLUE, GREEN], shown(water_game { |_, _| nil }, 1)
  end

  def test_one_word_changes_the_whole_group_on_the_next_frame
    program = water_game { |water, tick| water.show 1 if tick == 3 }

    assert_equal [RED, BLUE, GREEN], shown(program, 2)
    assert_equal [BLUE, GREEN, GREEN], shown(program, 5)
  end

  def test_the_number_can_be_worked_out_as_the_game_runs
    program = water_game { |water, tick| water.show((tick / 4) % 3) }

    assert_equal [GREEN, RED, GREEN], shown(program, 10)
  end

  def test_a_number_naming_no_picture_changes_nothing
    program = water_game do |water, tick|
      water.show 2 if tick == 2
      water.show 3 if tick == 4
      water.show(-1) if tick == 5
    end

    assert_equal [GREEN, RED, GREEN], shown(program, 8)
  end

  # Two areas of tiles on one background, each with the group among them at a place of its own.
  private def walking_game(&step)
    test = self.class
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :pond, %i[transparent red blue green]
      test.solid(self, :red_tile, 1)
      test.solid(self, :blue_tile, 2)
      test.solid(self, :green_tile, 3)
      image(:filler, width: 8, height: 8, colors: :pond, places: Array.new(64) { |i| 1 + (i % 3) })
      water = tile_pictures :water, colors: :pond, tiles: { top: %i[red_tile blue_tile] }
      tiles :near, "w" => water[:top], "#" => :green_tile
      tiles :far, "#" => :filler, "g" => :green_tile, "w" => water[:top]
      ground = background :ground, tiles: { near: :near, far: :far },
                                   map: { near: { pond: ["w#"] }, far: { lake: ["#gw"] } }
      tick = var :tick, 0
      game_loop do
        tick += 1
        instance_exec(ground, water, tick, &step)
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_group_shows_in_each_area_of_a_background_walking_between_them
    program = walking_game do |ground, water, tick|
      water.show 1 if tick == 2
      ground.show_map :lake if tick == 5
    end

    assert_equal BLUE, game_player.run(program, frames: 4).screen.pixel(4, 4), "the first area, the second picture"
    assert_equal BLUE, game_player.run(program, frames: 9).screen.pixel(20, 4), "the other area keeps the picture"
    assert_equal GREEN, game_player.run(program, frames: 9).screen.pixel(12, 4), "and its own tiles stay"
  end

  def test_a_picture_shown_after_walking_goes_where_the_group_sits_there
    program = walking_game do |ground, water, tick|
      ground.show_map :lake if tick == 2
      water.show 1 if tick == 6
    end

    assert_equal RED, game_player.run(program, frames: 5).screen.pixel(20, 4)
    assert_equal BLUE, game_player.run(program, frames: 9).screen.pixel(20, 4)
    assert_equal GREEN, game_player.run(program, frames: 9).screen.pixel(12, 4)
  end

  # The console's picture, frame for frame, against the interpreter's.
  def test_the_console_shows_the_group_as_the_interpreter_does
    program = water_game { |water, tick| water.show((tick / 2) % 3) }

    assert_backends_agree(program, frames: 9, name: "PICTURES")
  end

  def test_the_console_shows_the_group_in_the_area_walked_into
    program = walking_game do |ground, water, tick|
      water.show 1 if tick == 2
      ground.show_map :lake if tick == 5
      water.show 0 if tick == 8
    end

    assert_backends_agree(program, frames: 12, name: "PICTUREW")
  end

  def test_tiles_with_different_numbers_of_pictures_are_refused
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        colors :pond, %i[transparent red]
        TestTilePictures.solid(self, :one, 1)
        tile_pictures :water, colors: :pond, tiles: { a: %i[one one], b: %i[one] }
      end
    end

    assert_match(/different numbers of pictures/, error.message)
  end

  def test_a_picture_drawn_from_another_list_is_refused
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        colors :pond, %i[transparent red]
        colors :other, %i[transparent blue]
        image(:stray, width: 8, height: 8, colors: :other, places: Array.new(64, 1))
        tile_pictures :water, colors: :pond, tiles: { a: %i[stray] }
      end
    end

    assert_match(/not/, error.message)
    assert_match(/:stray/, error.message)
  end
end
