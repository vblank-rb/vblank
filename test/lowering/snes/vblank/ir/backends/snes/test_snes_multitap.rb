# frozen_string_literal: true

require "test_helper"
require "stringio"

# Four players on a Super Nintendo: the first controller, and three on a Super Multitap in the
# second port (SNES::Runtime::Frame#emit_tap_bits). A game finds the tap as it reads it; with a
# plain controller in the second port instead, that controller is the second player and the
# third and fourth hold nothing.
class TestSNESMultitap < Minitest::Test
  # A game for +players+: each player's steps counted while they hold right, and how many are
  # connected.
  def self.game(players)
    VBlank.game("TAP #{players}", consoles: %i[snes], players: players) do
      steps = (1..players).map { |player| var(:"steps#{player}", 0) }
      connected = var :connected, 0
      game_loop do
        steps.each.with_index(1) { |count, player| count.store!(count + 1) if held(:right, player: player) }
        connected.store!(players_connected)
      end
    end
  end

  private def built(players) = self.class.game(players).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Every routine of the runtime that reads or keeps the buttons, each label's master clocks a frame,
  # measured in bsnes with a tap in for a game of four (SNESProfiler).
  private def button_clocks(players)
    rows = built(players).profile(out: StringIO.new, settle: 10, frames: 20).runtime
    rows.select { |row| row.routine.to_s.match?(/pad|tap|button/) }.to_h { |row| [row.routine.to_s, row.share * FRAME_CLOCKS] }
  end

  # What the third and fourth players cost, against Nintendo's MULTI5 routine. MULTI5 takes the
  # first sixteen bits of controllers 1 to 3 from the console's automatic read, then clocks JOYSER1
  # by hand: sixteen reads to find the tap (fullsnes, "SNES Controllers Multiplayer 5"), and sixteen
  # more for the last two controllers, both lines a read. The budget is those 32 reads, each at what
  # a read of both lines costs here (the tap's first loop, rt_tap_read_first_plugs, which is that
  # same loop). Here the third and fourth players add 24 reads (eight to find the tap, sixteen for
  # the fourth), the third's line in the loop that reads the second, and two more controllers
  # turned into IR::Buttons's order and their presses kept.
  def test_the_third_and_fourth_players_cost_less_than_multi5s_hand_read
    four = button_clocks(4)
    extra = four.values.sum - button_clocks(2).values.sum
    budget = 32 * four.fetch("rt_tap_read_first_plugs") / 16

    assert_operator extra, :<, budget, "players 3 and 4 cost #{extra.round} master clocks a frame, MULTI5's hand read #{budget.round}"
  end

  # A game of two that asks how many are connected reads no tap.
  def test_a_game_of_two_reads_no_tap
    refute(button_clocks(2).keys.any? { |label| label.include?("tap") })
  end

  # The checked run plugs a tap in for a game of four, and the cartridge agrees with the
  # interpreter on every pass: the third player alone is three players connected.
  def test_the_third_player_alone_moves_and_counts_three_connected
    run = game_player.hold(:p3_right).run(self.class.game(4).program(console: :snes), frames: 6)

    assert_operator run[:steps3], :>, 0
    assert_equal 0, run[:steps2]
    assert_equal 3, run[:connected]
  end

  # On a Super FX cartridge the interrupt that lands while the chip runs a routine is the copy in
  # work RAM (Runtime::Chip), which reads the tap with no table. Each pass runs a routine on the chip
  # for frames on end, and the third player's taps and the fourth's right fall in those frames.
  def test_the_tap_is_read_while_a_super_fx_routine_runs
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes, variant: :superfx))
    b.instance_eval do
      total = var :total, 0
      taps = var :taps, 0
      rights = var :rights, 0
      func(:heavy, on_chip: true) { repeat(30) { repeat(1000) { |i| total.store!(total + (i * 3) - (total >> 2)) } } }
      game_loop do
        call :heavy
        taps.store!(taps + 1) if pressed(:a, player: 3)
        rights.store!(rights + 1) if held(:right, player: 4)
      end
    end
    b.finalize_program
    presses = ->(frame) { [(:p3_a if (frame % 4).zero?), (:p4_right if frame > 10)].compact }
    run = game_player.input_each_frame(&presses).run(b.program, frames: 30)

    assert_operator run[:taps], :>, 1
    # Right is held from frame 11. A pass of one frame would see it on 20 of the 30; more means
    # each pass took several frames, so the chip was running as their blanks came.
    assert_operator run[:rights], :>, 20
  end

  # The Verifier plugs no tap in: bsnes has a plain controller in the second port, which hands over
  # bits of 1 once its sixteen are read. The game believes no tap is there and reads none of them.
  def test_with_no_multitap_the_third_and_fourth_players_hold_nothing
    rom = built(4)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 4, vars: rom.var_addresses)
    reader.step(6, keys: VBlank::IR::Buttons.mask(%i[p2_right p3_right p4_right]))

    assert_operator reader.var(:steps2), :>, 0, "the second port's own controller is the second player"
    assert_equal [0, 0], [reader.var(:steps3), reader.var(:steps4)]
    assert_equal 2, reader.var(:connected)
  end

  def test_with_no_multitap_and_nobody_at_the_second_port_one_player_is_connected
    rom = built(4)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 4, vars: rom.var_addresses)
    reader.step(6, keys: VBlank::IR::Buttons.mask(%i[right]))

    assert_equal 1, reader.var(:connected)
    assert_equal [0, 0, 0], (2..4).map { |player| reader.var(:"steps#{player}") }
  end
end
