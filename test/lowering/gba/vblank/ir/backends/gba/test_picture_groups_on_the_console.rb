# frozen_string_literal: true

require "test_helper"
require "differential"

# A scene's pictures in groups, on the console: only the groups up are in sprite memory.
#
# Each grouped picture has one place there, shared with pictures whose groups are never up with
# its own, and it is copied in between frames as one of its groups comes up. So the pictures have
# to be right on the very frame a sprite first shows them: after a change of room, while two
# rooms are up as the screen slides, and back in a scene after another scene's pictures went
# into the same memory. And a scene whose rooms would not all fit at once builds, since only the
# rooms up at once have to.
class TestPictureGroupsOnTheConsole < Minitest::Test
  include Differential

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| VBlank::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # A 64x64 picture filling its square and differing from every other: a slanted stripe pattern
  # shifted by the picture's number, with the number written along the top row.
  def big_art(number)
    (0...64).flat_map do |y|
      (0...64).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # A program built through the DSL; the block is handed this test, for its pictures.
  private def program(&block)
    b = Builder.new
    b.instance_exec(self, &block)
    b.finalize_program
    b.program
  end

  # Four rooms in a row, a picture each, walked through a room every four passes, with the next
  # one up beside it for the two passes before the screen gets there. One sprite shows the room
  # the game is in and the other the room beside, and the hero shows in every room.
  private def walk_through_four_rooms
    program do |t|
      screen :tiled
      rooms = (0...4).map { |n| :"room_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      image :hero, width: 64, height: 64, data: t.big_art(50)
      passes = 0
      here = 0
      beside = 0
      up = picture_groups :rooms, rooms.each_with_index.to_h { |name, n| [n, [name]] },
                          up_together: [[0, 1], [1, 2], [2, 3]]
      this_room = sprite :this_room, facing: rooms.to_h { |name| [name, name] }, at: [8, 8]
      next_room = sprite :next_room, facing: rooms.to_h { |name| [name, name] }, at: [88, 8]
      sprite :hero, facing: { hero: :hero }, at: [168, 8]
      show = lambda do
        up.show here, beside
        this_room.face rooms, showing: here
        next_room.face rooms, showing: beside
      end
      show.call
      game_loop do
        passes += 1
        here = (passes / 4).clamp(0, 3)
        beside = ((passes + 2) / 4).clamp(0, 3)
        show.call
      end
    end
  end

  def test_each_room_shows_right_on_the_frame_it_comes_up
    prog = walk_through_four_rooms
    (2..15).each { |frames| assert_backends_agree(prog, frames: frames, name: "ROOMS") }
  end

  # Forty rooms, a 64x64 picture each: two kilobytes a room, eighty for all forty, which is more
  # than the console's sprite memory holds. A pool of twenty things can show any room's picture,
  # so keeping each thing to one frame at a time would not fit either: forty kilobytes. One room
  # is up at a time, so the scene needs one room's room. The game opens on another scene, whose
  # pictures fill the same memory, and goes back to it and comes back, so the scene's rooms have
  # to come up again after it.
  ROOM_COUNT = 40

  private def maze_of_forty_rooms
    program do |t|
      screen :tiled
      rooms = (0...ROOM_COUNT).map { |n| :"cell_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = 1
      tick = 0
      scene(:maze) do
        up = picture_groups :cells, rooms.each_with_index.to_h { |name, n| [n, [name]] }
        things = pool :thing, x: 0, y: 0, capacity: 20, facing: rooms.to_h { |name| [name, name] }
        if things.count == 0
          things.spawn(x: 8, y: 8)
          things.spawn(x: 88, y: 40)
        end
        room = (tick * 7) % ROOM_COUNT
        up.show room
        things.each { |thing| thing.face rooms, showing: room }
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick += 1
        state = 0 if tick == 3
        state = 1 if tick == 8
        state = 0 if tick == 10
        case_var(:state) { when_val 0, :maze; when_val 1, :away }
      end
    end
  end

  # Groups of every screen, kept across a change of scene. The game says which room is up from
  # its own loop, outside any scene, so the groups are the game's and stay up while another
  # scene's pictures fill the memory above them; coming back, nothing has to be copied again. The
  # walker shows its room's picture both ways round, the turned one drawn from the same tiles.
  private def walker_between_scenes
    program do |t|
      screen :tiled
      image :room_0, width: 64, height: 64, data: t.big_art(0)
      image :room_1, width: 64, height: 64, data: t.big_art(1)
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = 0
      tick = 0
      here = 0
      look = 0
      up = picture_groups :rooms, { 0 => %i[room_0], 1 => %i[room_1] }
      scene(:walking) do
        walker = sprite :walker, facing: { ahead: :room_0, back: mirror(:room_0), other: :room_1 }, at: [8, 8]
        walker.face %i[ahead back other], showing: look
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      up.show here
      game_loop do
        tick += 1
        here = (tick / 6) % 2
        look = here * 2
        look = tick % 2 if here == 0
        up.show here
        state = 1 if tick == 3
        state = 0 if tick == 5
        case_var(:state) { when_val 0, :walking; when_val 1, :away }
      end
    end
  end

  # A scene that loads first, given the screen back. Its room is up as it leaves, and the scene
  # away fills sprite memory with pictures of its own. Back again, none of the harbor's code runs
  # on the pass it takes over on, and its things are drawn after that pass showing the room they
  # showed as it was left: its pictures have to be back in their places by then.
  private def harbor_given_back
    program do |t|
      screen :tiled
      rooms = (0...2).map { |n| :"dock_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = 0
      tick = 0
      scene(:harbor, loads_first: true) do
        up = picture_groups :docks, rooms.each_with_index.to_h { |name, n| [n, [name]] }
        boats = pool :boat, x: 0, y: 0, capacity: 4, facing: rooms.to_h { |name| [name, name] }
        if boats.count == 0
          boats.spawn(x: 8, y: 8)
          boats.spawn(x: 88, y: 40)
        end
        up.show 1
        boats.each { |boat| boat.face rooms, showing: 1 }
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick += 1
        state = 1 if tick == 3
        state = 0 if tick == 6
        case_var(:state) { when_val 0, :harbor; when_val 1, :away }
      end
    end
  end

  # Frames 3 and 6 are the frames each scene takes over on, where the scene leaving still has
  # its sprites up over pictures the next one is copying in. Frame 7 is the first the harbor's
  # boats are drawn again.
  def test_a_scene_that_loads_first_shows_its_rooms_on_the_pass_it_is_given_back
    prog = harbor_given_back
    [2, 4, 5, 7, 8, 10].each { |frames| assert_backends_agree(prog, frames: frames, name: "HARBOR") }
  end

  def test_groups_of_every_screen_stay_up_across_a_change_of_scene
    prog = walker_between_scenes
    [2, 4, 6, 7, 8, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "WALKER") }
  end

  def test_a_scene_whose_rooms_would_not_all_fit_builds_and_plays
    prog = maze_of_forty_rooms
    [5, 7, 12, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "MAZE") }
  end

  # The sprite table goes in before a group's pictures. The table must be written while nothing is
  # drawn (GBATEK, OAM: the display reads it as it draws each row), and a group's pictures are a big
  # copy. Copied first, they push the table's writes down the gap, and a copy longer than what is
  # left of the gap pushes them into the picture, where a row of sprites tears. So the table lands
  # on the same rows of the gap on a frame a group comes up as on a frame nothing is copied.
  ROOM_PICTURES = 8 # 64x64 pictures a room: sixteen kilobytes, a good part of the gap to copy

  private def two_big_rooms
    program do |t|
      screen :tiled
      pictures = (0...(ROOM_PICTURES * 2)).map { |n| :"wall_#{n}" }
      pictures.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      image(:dot, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      rooms = picture_groups :walls, { 0 => pictures.first(ROOM_PICTURES), 1 => pictures.last(ROOM_PICTURES) }
      wall = sprite :wall, facing: pictures.to_h { |name| [name, name] }, at: [8, 90]
      runner = sprite :runner, at: [0, 0], facing: { still: :dot }
      passes = 0
      room = 0
      rooms.show 0
      wall.face pictures, showing: 0
      game_loop do
        passes += 1
        room = (passes / 4) % 2
        rooms.show room
        wall.face pictures, showing: room * ROOM_PICTURES
        runner.move_to passes, 0
      end
    end
  end

  def test_the_sprite_table_is_written_before_a_group_is_copied_in
    # From the third frame on, a room comes up every fourth one and the runner moves on every one.
    last_rows = sprite_table_rows_by_frame(two_big_rooms, frames: 16).map(&:max)

    assert_equal [last_rows[3]], last_rows[3..].uniq, "the last row a write to the sprite table landed on, by frame: #{last_rows}"
  end

  # The rows each frame's writes to the sprite table landed on, a list a frame from power-on.
  private def sprite_table_rows_by_frame(game, frames:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rooms.gba")
      assemble_rom(game, name: "ROOMS").write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        Array.new(frames) do
          probe.display_writes.clear
          probe.step(1)
          probe.display_writes.select { |write| write.kind == :sprite }.map(&:row)
        end
      ensure
        probe.close
      end
    end
  end
end
