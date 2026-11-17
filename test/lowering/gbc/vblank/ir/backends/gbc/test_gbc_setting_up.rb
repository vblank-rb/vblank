# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# HOW LONG A COLOR CARTRIDGE TAKES FROM POWER-ON TO THE GAME'S FIRST PASS. Every Color game clears
# work memory and both banks of video memory before its first line, which a console's own games do
# in a frame or so with the fastest loop and the console's own copy (Runtime::Boot). What a game
# declares is set up after that, and takes what it takes. frames_since_power_on, read on the first
# pass, counts every frame setting up took, whatever the game's size.
class TestGBCSettingUp < Minitest::Test
  include PowerOnFrameGames

  # A game of +vars+ variables and +lists+ lists of 16 slots, each started at a number of its own.
  # +busy+ turns of a spin before the loop make setting up that much longer.
  private def declaring_game(vars, lists, busy: 0)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      many = Array.new(vars) { |n| var :"v_#{n}", n + 1 }
      held = Array.new(lists) { |n| list :"l_#{n}", capacity: 16, full_of: n + 1 }
      spin = 0
      repeat(busy) { spin += 1 } if busy.positive?
      passes = 0
      first = -1
      sum = 0
      game_loop do
        first = frames_since_power_on if passes == 0
        passes += 1
        sum = many.first(2).sum + held.first(2).sum { |list| list[0] }
      end
    end
    b.finalize_program
    b.program
  end

  # The memories cleared within the first frame: the first pass is seen on the second.
  def test_a_small_game_passes_first_on_the_second_frame
    frame, reading = first_pass_frame_and_reading(:gbc, declaring_game(2, 2))

    assert_equal [2, 1], [frame, reading]
  end

  # Seven hundred variables and forty lists, which keep both halves of work memory: two frames of
  # setting up more, and the first pass reads them all.
  def test_a_game_of_many_declarations_passes_first_by_the_fourth_frame
    frame, reading = first_pass_frame_and_reading(:gbc, declaring_game(700, 40))

    assert_operator frame, :<=, 4
    assert_equal frame - 1, reading
  end

  # WHEREVER SETTING UP ENDS AGAINST A FRAME'S END, the first pass reads the frames gone before it.
  # Setting up that ends a turn of a spin later can put the first pass a frame later, and the turns
  # either side of each place it does are where a count kept apart from the emulator's frames can
  # disagree with them. Each such place over the first few frames, found by halving, and the turns
  # around it, read right: for a small game, and for one that keeps both halves of work memory.
  def test_the_first_pass_reads_the_frames_gone_wherever_setting_up_ends
    misread = [[2, 2], [700, 40]].flat_map do |vars, lists|
      frame_ends_crossed(vars, lists, 0..1_600).flat_map do |busy|
        (busy - 2..busy + 3).filter_map do |near|
          frame, reading = first_pass_frame_and_reading(:gbc, declaring_game(vars, lists, busy: near))
          "#{vars} variables, #{near} turns: seen on #{frame}, read #{reading}" unless reading == frame - 1
        end
      end
    end

    assert_empty misread, "the first pass reads one more or less than the frames gone before it"
  end

  # The turns of the spin, within +turns+, after which a game of +vars+ variables and +lists+ lists
  # passes first a frame later than after the turn before.
  private def frame_ends_crossed(vars, lists, turns)
    frame_after = Hash.new { |seen, busy| seen[busy] = first_pass_frame_and_reading(:gbc, declaring_game(vars, lists, busy: busy)).first }
    turns.step(100).each_cons(2).flat_map do |low, high|
      next [] if frame_after[low] == frame_after[high]

      while high - low > 1
        middle = (low + high) / 2
        frame_after[middle] == frame_after[low] ? low = middle : high = middle
      end
      [high]
    end
  end
end
