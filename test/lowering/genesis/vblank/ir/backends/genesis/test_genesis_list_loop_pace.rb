# frozen_string_literal: true

require "test_helper"
require "stringio"

# TEN MOVING PARTS RUN BY A GAME'S OWN LOGIC: a loop of ten, each turn reading four slots of the
# game's lists and writing two, every eighth pass, so the loop's cost is one frame's against the
# frames beside it.
#
# A retail game does a turn of that in a few dozen instructions: the part's number in a register,
# each list read and written through an address register, and a branch back.
module ListLoopGames
  PARTS = 10
  EVERY = 8

  # The game. +counted+ keeps the count in a variable, so nothing is known of the index while the
  # game is built and every read and write is checked as it runs; without, the count is written in
  # the game and no read or write needs a check.
  def self.game(counted:)
    parts = PARTS
    every = EVERY
    VBlank.game("TEN PARTS", consoles: %i[genesis]) do
      xs = list :xs, capacity: parts, full_of: 0
      ys = list :ys, capacity: parts, full_of: 0
      across = list :across, capacity: parts, width: :byte, full_of: 3
      down = list :down, capacity: parts, width: :half, full_of: -2
      turn = var :turn, 0
      count = var :count, parts
      game_loop do
        turn += 1
        if turn == every
          turn = 0
          repeat(counted ? count : parts) do |part|
            xs[part] = (xs[part] + across[part]) & 255
            ys[part] = (ys[part] + down[part]) & 127
            across[part] = across[part] + 1 if part == 3
          end
        end
      end
    end
  end

  RUN = 64

  # A run of 64 of a table's entries copied into a list every fourth pass, a run further on each
  # time: a frame of an animation, a row of a level. +width+ is the size of an entry and a slot.
  def self.copying_game(width)
    run = RUN
    VBlank.game("TEN PARTS", consoles: %i[genesis]) do
      letters = table :letters, Array.new(run * 4) { |at| (at * 7) % 100 }, width: width
      name = list :name, capacity: run, width: width
      pass = var :pass, 0
      game_loop do
        pass += 1
        name.copy_from letters, at: ((pass >> 2) & 3) * run, count: run if (pass & 3) == 0
      end
    end
  end
end

# WHAT THAT LOOP COSTS THE GENESIS, measured in the emulator, and that the lists hold what the
# interpreter's hold.
class TestGenesisListLoopPace < Minitest::Test
  # How much of a frame the pass that runs the loop may take over a pass that does not: with the
  # count written in the game, and with a count the game keeps. Measured, each list read or
  # written is a few instructions where the game reads it, with no call, and a check of the index
  # only where the count is not known; and the loop's count is kept in a register.
  MOST_OF_A_FRAME = 0.034
  MOST_OF_A_FRAME_COUNTED = 0.045

  # ...and a run of 64 entries copied from a table into a list. Measured, an entry is one
  # instruction and the count's, where a call for its place in the table and two for its slot
  # took a sixth of a frame for the run.
  MOST_OF_A_FRAME_COPYING = 0.016

  PASSES = 32

  TAPE = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: TEN PARTS 0x00000000
    starts from: power-on
  TAPE

  def test_the_lists_hold_what_the_interpreters_hold
    [false, true].each do |counted|
      run = game_player.run(ListLoopGames.game(counted: counted).program(console: :genesis), frames: 40)

      # Five loops of three across, and the fourth part a step quicker each loop.
      assert_equal [15, 15, 15, 25, 15, 15, 15, 15, 15, 15], run.list(:xs)
      assert_equal [118] * ListLoopGames::PARTS, run.list(:ys), "five loops of two up, held to 0..127"
    end
  end

  def test_the_loop_with_its_count_written_takes_little_of_a_frame
    share = loop_share(counted: false)

    assert_operator share, :<=, MOST_OF_A_FRAME, "the loop takes #{(share * 100).round(2)}% of a frame"
  end

  def test_the_loop_with_a_count_the_game_keeps_takes_little_of_a_frame
    share = loop_share(counted: true)

    assert_operator share, :<=, MOST_OF_A_FRAME_COUNTED, "the loop takes #{(share * 100).round(2)}% of a frame"
  end

  def test_a_copied_run_holds_what_the_interpreters_holds
    %i[byte half].each do |width|
      run = game_player.run(ListLoopGames.copying_game(width).program(console: :genesis), frames: 10)

      assert_equal Array.new(ListLoopGames::RUN) { |at| (((2 * ListLoopGames::RUN) + at) * 7) % 100 }, run.list(:name),
                   "the third run, copied on the eighth pass"
    end
  end

  def test_copying_a_run_of_a_table_takes_little_of_a_frame
    %i[byte half].each do |width|
      share = busiest_over_quietest(ListLoopGames.copying_game(width))

      assert_operator share, :<=, MOST_OF_A_FRAME_COPYING, "a run of #{width}s takes #{(share * 100).round(2)}% of a frame"
    end
  end

  private

  def loop_share(counted:) = busiest_over_quietest(ListLoopGames.game(counted: counted))

  # How much more of a frame the busiest frame takes than the quietest: the loop, or the copy.
  def busiest_over_quietest(game)
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    still = rom.profile(out: StringIO.new, frames: PASSES)
    shares = rom.profile(out: StringIO.new, tape: TAPE, frames: still.measured_frames).readings.map(&:awake_share)
    shares.max - shares.min
  end
end
