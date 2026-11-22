# frozen_string_literal: true

require "test_helper"
require "stringio"

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
