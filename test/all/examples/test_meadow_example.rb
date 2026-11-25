# frozen_string_literal: true

require "test_helper"
ShareableConstants.require_file(VBlank.root.join("examples/meadow").to_s)

# The Meadow example (examples/meadow.rb): a hero walks out of a one-screen cabin into a
# meadow of 120x100 cells, far bigger than the console's grid. The streaming itself is
# pinned in test/all/vblank/builder/test_big_maps.rb; this confirms the example walks out the
# door, on every console the game is written for, each run's own build held to the interpreter.
#
# Going through the door is the example's showcase of `pixelate_out` and `pixelate_in`: the
# picture breaks up into blocks, the room is swapped while nobody can read it, and it comes
# back together, with the room's name kept sharp throughout.
#
# Which room a picture shows is read off the picture, by the name in its corner, and never
# off the game's `room` variable: the room a frame draws is the one the variable held a
# frame before (see "Which frame's numbers the picture was drawn from" in the testing rules).
# The Advance's cartridge is checked against the interpreter in
# test/console/gba/examples/test_meadow_example_on_the_advance.rb.
#
# The walk out of the cabin and the pictures it makes, for this file's tests and the Advance's cartridge test
# (test/console/gba/examples/test_meadow_example_on_the_advance.rb).
module MeadowWalk
  WHITE = VBlank::Testing.shown(:white)
  BIGGEST = Meadow::BIGGEST_BLOCK

  private def program
    skip_unless_written_for Meadow::GAME
    Meadow::GAME.program(console: game_console)
  end

  private def width = described_game_console.screen_width
  private def height = described_game_console.screen_height

  # The picture after each of the first frames of the walk with DOWN held: far enough to
  # reach the cabin door, go through it, and walk a little way down the path.
  private def pictures_of_walk_out(frames = 70)
    (1..frames).map do |n|
      screen = game_player.hold(:down).run(program, frames: n).screen
      Array.new(height) { |y| Array.new(width) { |x| screen.pixel(x, y) } }
    end
  end

  # Is the bottom left of the picture — clear of the hero, wherever he stands in either
  # room, and of the room's name — in blocks of +size+: every pixel the colour at the corner
  # of its block?
  private def bottom_in_blocks?(picture, size)
    (96...height).all? do |y|
      (0...96).all? { |x| picture[y][x] == picture[y - (y % size)][x - (x % size)] }
    end
  end

  # The sizes of block the bottom left of the picture is in, 1 left out since every
  # picture is in blocks of one pixel. None for a picture as drawn.
  private def block_sizes(picture) = (2..BIGGEST).select { |size| bottom_in_blocks?(picture, size) }

  # Where the room's name is: every white pixel, which nothing else in either room is.
  private def lettering(picture)
    (0...height).to_a.product((0...width).to_a).select { |y, x| picture[y][x] == WHITE }
  end

  # The walk as its pictures, and the two frames that bound the change: the first one in
  # blocks at all, and the first one whose name is the meadow's.
  private def walk_through_door
    pictures = pictures_of_walk_out
    cabin_name = lettering(pictures[2])
    broke_up = pictures.find_index { |picture| block_sizes(picture).any? }
    swapped = pictures.find_index { |picture| lettering(picture) != cabin_name }
    [pictures, broke_up, swapped]
  end
end

class TestMeadowExample < Minitest::Test
  include MeadowWalk

  def test_holding_down_walks_out_of_the_cabin_into_the_meadow
    run = game_player.hold(:down).run(program, frames: 70)
    assert_equal 1, run[:room], "out of the door and into the meadow"
    assert_operator run[:view_y], :>, 0, "the view follows the hero down the path"
  end

  # The door is not a cut any more: the hero stops in it, and the cabin stays the room
  # for the frames the picture takes to break up.
  def test_the_hero_stops_in_the_doorway_while_the_picture_breaks_up
    stopped = (1..50).map { |n| game_player.hold(:down).run(program, frames: n)[:hero_y] }
                     .each_cons(2).find_index { |before, after| before == after }
    pictures, broke_up, swapped = walk_through_door

    refute_nil stopped, "he stops, though DOWN is still held"
    assert_operator swapped - broke_up, :>=, Meadow::DOOR_FRAMES - 2, "and the cabin is the room for as long as that takes"
    assert_empty block_sizes(pictures[broke_up - 1]), "from a picture that was as drawn"
  end

  # The swap is hidden on both sides: the last picture of the cabin and the first of the
  # meadow are both in the biggest blocks.
  def test_the_room_is_swapped_between_two_pictures_in_the_biggest_blocks
    pictures, _broke_up, swapped = walk_through_door
    last_of_cabin = pictures[swapped - 1]
    first_of_meadow = pictures[swapped]

    assert bottom_in_blocks?(last_of_cabin, BIGGEST), "the cabin's last picture"
    assert bottom_in_blocks?(first_of_meadow, BIGGEST), "and the meadow's first"
    refute_equal last_of_cabin[height - 1][0], first_of_meadow[height - 1][0], "which is a different room: floor boards, then grass"
  end

  def test_the_picture_comes_back_together_in_the_meadow_a_size_at_a_time
    pictures, _broke_up, swapped = walk_through_door
    part_way = block_sizes(pictures[swapped + 5])

    refute_empty part_way, "part way back it is still in blocks"
    refute_includes part_way, BIGGEST, "but smaller ones"
    assert_empty block_sizes(pictures.last), "and at the end it is as drawn"
  end

  # The name of the room is in a layer the blocks are placed under, so it is readable on
  # every frame of the change, and it changes on the frame the room does.
  def test_the_name_of_the_room_stays_sharp_on_every_frame_of_the_change
    pictures, broke_up, swapped = walk_through_door
    cabin = lettering(pictures[2])
    meadow = lettering(pictures.last)

    refute_empty cabin
    refute_equal cabin, meadow, "the two rooms have different names"
    assert(pictures[broke_up...swapped].all? { |picture| lettering(picture) == cabin }, "CABIN is as drawn while the picture breaks up")
    assert(pictures[swapped..].all? { |picture| lettering(picture) == meadow }, "and MEADOW from the swap on")
  end
end
