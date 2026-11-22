# frozen_string_literal: true

require "test_helper"
require "stringio"
require "many_tiles"

# A background bent row by row on a Genesis (Lowering::Bends): the video chip told to scroll a line at a
# time, every line's scroll worked out into a table as the pass ends (Runtime::Tiles' rt_picture_prepare)
# and sent in the blank by the chip's own copy. What a bend means is test_row_bend.rb's, played on every
# run; here are the Genesis's own two planes, and what its line table costs, measured in the emulator.
class TestGenesisBentRows < Minitest::Test
  PASSES = 24

  # The line table's share of each frame, for one plane bent and one plane straight that holds still:
  # the bent plane's 224 lines at four instructions a line, eight lines a turn of the loop, and the
  # straight plane's one comparison. There is no game of the console's own measured for this yet, so
  # this is a budget: a sixteenth of the frame, sixteen lines of the 262, which leaves a game bending
  # one plane its frame but for the rows its own block takes. Measured, a little over a twentieth.
  LINES_MOST = 1.0 / 16

  # The chip's copy of the table in the blank: 448 words, which the processor waits out with the bus
  # given away. A fortieth of the frame, about six lines of the blank's own thirty-eight.
  SENT_MOST = 1.0 / 40

  # The same, a straight plane scrolling every pass: its 224 lines at one instruction a line on top.
  SCROLLING_STRAIGHT_MOST = 1.0 / 10

  private def two_planes(name, straight_scrolls: false)
    VBlank.game(name, consoles: %i[genesis]) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:dot, "." => :transparent, "#" => :blue) { (["....#..."] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      tiles :spots, "#" => :dot
      hills = background :hills, tiles: :spots, map: Array.new(28) { "#" * 40 }
      water = background :water, tiles: :stripes, map: Array.new(28) { "#" * 40 }
      ripple = table :ripple, (0...64).map { |i| (Math.sin(i * 2 * Math::PI / 64) * 3).round }
      phase = var :phase, 0
      water.scroll_each_row { |row| ripple[(row + phase) & 63] }
      game_loop do
        phase += 1
        water.scroll_to phase, 0
        hills.scroll_to phase * 2, 0 if straight_scrolls
      end
    end
  end

  # What +game+ spent of each frame on the line table and on sending it, over PASSES passes.
  private def shares(game)
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    lines = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(picture_prepare|scroll_lines)/) }.sum(&:share)
    sent = result.runtime.select { |spent| spent.routine.to_s == "rt_vram_copy" }.sum(&:share)
    [lines, sent]
  end

  # The bent plane in front, the straight one behind, both on screen, against the interpreter on every pass.
  def test_a_bent_plane_and_a_straight_one_show_what_the_interpreter_shows
    game_player.run(two_planes("BENT BESIDE STILL").program(console: :genesis), frames: 12)
  end

  # A straight plane whose scroll moves is written again each pass, beside the bent one.
  def test_a_straight_plane_that_scrolls_beside_a_bent_one_shows_what_the_interpreter_shows
    game_player.run(two_planes("BENT BESIDE MOVING", straight_scrolls: true).program(console: :genesis), frames: 12)
  end

  def test_the_line_table_takes_no_more_than_its_budget
    lines, sent = shares(two_planes("BENT LINES COST"))

    assert_operator lines, :<=, LINES_MOST, "the line table's share of each frame"
    assert_operator sent, :<=, SENT_MOST, "sending it in the blank"
  end

  def test_a_straight_plane_that_scrolls_adds_its_lines_alone
    lines, = shares(two_planes("BENT MOVING COST", straight_scrolls: true))

    assert_operator lines, :<=, SCROLLING_STRAIGHT_MOST, "the line table's share of each frame"
  end

  # The background behind, on plane B, bent, and the one in front straight: each plane's half of a line.
  def test_a_bend_on_plane_b_shows_what_the_interpreter_shows
    game = VBlank.game("BENT PLANE B", consoles: %i[genesis]) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:dot, "." => :transparent, "#" => :blue) { (["....#..."] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      tiles :spots, "#" => :dot
      hills = background :hills, tiles: :stripes, map: Array.new(28) { "#" * 40 }
      background :water, tiles: :spots, map: Array.new(28) { "#" * 40 }
      phase = var :phase, 0
      hills.scroll_each_row { |row| (row + phase) % 6 }
      game_loop { phase += 1 }
    end
    game_player.run(game.program(console: :genesis), frames: 10)
  end

  # Another map of a bent background put up: the plane still shows the background's bend.
  def test_a_bent_background_showing_another_map_stays_bent
    game = VBlank.game("BENT NEW MAP", consoles: %i[genesis]) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:dot, "." => :transparent, "#" => :blue) { (["....#..."] * 8).join("\n") }
      tiles :set, "#" => :bar, "o" => :dot
      water = background :water, tiles: :set, map: { calm: Array.new(28) { "#" * 40 }, rough: Array.new(28) { "o" * 40 } }
      tick = var :tick, 0
      water.scroll_each_row { |row| (row + tick) % 8 }
      game_loop do
        tick += 1
        water.show_map :rough if tick == 3
        water.show_map :calm if tick == 6
      end
    end
    game_player.run(game.program(console: :genesis), frames: 10)
  end

  # The lines a blank has, NTSC's (Console::GenesisHardware::BLANK_DMA_BYTES counts the same 38), and the
  # lines of a frame the profile's shares are of.
  BLANK_LINES = 38
  FRAME_LINES = 262

  # A big sprite kept to a room of one pose (Lowering::PoseRooms), changing pose every pass, over a
  # bending background of many tiles: the room, the sprite table, the colours and the line table all
  # copied in every blank.
  private def pose_room_over_a_bend(walkers)
    VBlank.game("POSE ROOM BEND", consoles: %i[genesis]) do
      screen :tiled
      map = ManyTiles.declare(self, :ground, 400, :red)
      ground = background :ground, tiles: :ground, map: map
      frames = ManyTiles.declare_sprite_pictures(self, :boss, 16, :green, from: 400)
      Array.new(walkers) { |i| sprite :"walker_#{i}", at: [8 + (i * 90), 16], frames: frames, rate: 1 }
      tick = var :tick, 0
      ground.scroll_each_row { |row| (row + tick) & 7 }
      game_loop { tick += 1 }
    end
  end

  # Every copy of the blank, measured in the emulator: the room's new pose and the line table with the
  # rest still land before the screen is drawn, and the picture is the interpreter's on every pass.
  def test_a_pose_room_beside_the_line_table_lands_every_copy_in_the_blank
    game = pose_room_over_a_bend(1)
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)
    copied = result.runtime.select { |spent| spent.routine.to_s.match?(/\A(rt_vram_copy|rt_upload|art poses sent)/) }.sum(&:share)

    assert_operator copied * FRAME_LINES, :<=, BLANK_LINES, "lines of the blank the copies took"
    game_player.run(game.program(console: :genesis), frames: 12)
  end

  # Two such rooms beside the line table are more than the chip copies in a blank (they took 44 lines
  # of the 38 before the rooms were held to the blank left beside it), so the build keeps neither to a
  # room, and says the pictures do not fit.
  def test_pose_rooms_are_held_to_the_blank_left_beside_the_line_table
    error = assert_raises(VBlank::IR::Backends::Genesis::Art::TooManyTiles) do
      pose_room_over_a_bend(2).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_includes error.message, "room for #{VBlank::IR::Backends::Genesis::Art::MOST_TILES}"
  end

  # A game that bends nothing keeps the whole-screen scroll, and spends nothing on lines.
  def test_a_game_that_bends_nothing_works_out_no_lines
    game = VBlank.game("NO BEND LINES", consoles: %i[genesis]) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(28) { "#" * 40 }
      across = var :across, 0
      game_loop do
        across += 1
        water.scroll_to across, 0
      end
    end
    lines, sent = shares(game)

    assert_in_delta 0, lines, 0.001
    assert_in_delta 0, sent, 0.001
  end
end
