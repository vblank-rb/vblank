# frozen_string_literal: true

require "test_helper"

# A BIG TILE TAKING TURNS THROUGH PICTURES. A Super Nintendo draws a background from tiles of 16×16
# as readily as from 8×8, and a stage of blocks that shimmer together is one tile changing its
# picture, wherever on the map it stands. This is the one console that does, so it is here, and
# every run playing games as the console plays it.
class TestBigTilePicturesOnTheSuperNintendo < Minitest::Test
  RED = 0x001F
  GREEN = 0x03E0
  BLUE = 0x7C00
  WHITE = 0x7FFF

  # A 16×16 picture of four quarters, in places +a+ to +d+ of the list :block, left to right and then
  # down, so a quarter out of place shows as a colour in the wrong corner.
  def self.quartered(builder, name, a, b, c, d)
    places = Array.new(256) do |at|
      top = (at / 16) < 8
      left = (at % 16) < 8
      if top then left ? a : b
      else left ? c : d
      end
    end
    builder.image(name, width: 16, height: 16, colors: :block, places: places)
    name
  end

  private def block_game(&step)
    test = self.class
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    builder.instance_eval do
      screen :tiled
      colors :block, %i[transparent red green blue white]
      test.quartered(self, :first, 1, 2, 3, 4)
      test.quartered(self, :second, 4, 3, 2, 1)
      test.quartered(self, :wall, 3, 3, 3, 3)
      blocks = tile_pictures :blocks, colors: :block, tiles: { soft: %i[first second] }
      tiles :stage, "s" => blocks[:soft], "#" => :wall
      background :ground, tiles: :stage, map: ["s#s"]
      tick = var :tick, 0
      game_loop do
        tick += 1
        instance_exec(blocks, tick, &step)
      end
    end
    builder.finalize_program
    builder.program
  end

  # The four quarters of the cell starting at +left+.
  private def quarters(screen, left) = [screen.pixel(left + 4, 4), screen.pixel(left + 12, 4), screen.pixel(left + 4, 12), screen.pixel(left + 12, 12)]

  def test_a_big_tile_shows_its_first_picture_in_every_cell
    screen = game_player.run(block_game { |_, _| nil }, frames: 3).screen

    assert_equal [RED, GREEN, BLUE, WHITE], quarters(screen, 0)
    assert_equal [RED, GREEN, BLUE, WHITE], quarters(screen, 32)
    assert_equal [BLUE, BLUE, BLUE, BLUE], quarters(screen, 16)
  end

  def test_one_word_changes_every_cell_showing_the_tile
    program = block_game { |blocks, tick| blocks.show 1 if tick == 3 }
    screen = game_player.run(program, frames: 8).screen

    assert_equal [WHITE, BLUE, GREEN, RED], quarters(screen, 0)
    assert_equal [WHITE, BLUE, GREEN, RED], quarters(screen, 32)
    assert_equal [BLUE, BLUE, BLUE, BLUE], quarters(screen, 16)
  end

  def test_the_picture_can_turn_every_few_frames
    program = block_game { |blocks, tick| blocks.show((tick / 7) % 2) }

    assert_equal [WHITE, BLUE, GREEN, RED], quarters(game_player.run(program, frames: 10).screen, 32)
    assert_equal [RED, GREEN, BLUE, WHITE], quarters(game_player.run(program, frames: 17).screen, 32)
  end

  def test_pictures_of_two_sizes_in_one_group_are_refused
    error = assert_raises(ArgumentError) do
      builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
      test = self.class
      builder.instance_eval do
        colors :block, %i[transparent red green blue white]
        test.quartered(self, :big, 1, 2, 3, 4)
        image(:small, width: 8, height: 8, colors: :block, places: Array.new(64, 1))
        tile_pictures :blocks, colors: :block, tiles: { soft: %i[big small] }
      end
    end

    assert_match(/same size/, error.message)
  end
end
