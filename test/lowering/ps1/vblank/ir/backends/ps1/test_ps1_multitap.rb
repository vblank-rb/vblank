# frozen_string_literal: true

require "test_helper"
require "stringio"

# Four players on a PlayStation: the first port's pad, and three on Sony's Multitap in the second port
# (PS1::Runtime::Pads). A game finds the tap as it reads it; with a plain pad in the second port
# instead, that pad is the second player and the third and fourth hold nothing.
class TestPS1Multitap < Minitest::Test
  # A game for +players+: each player's steps counted while they hold right, and, for more than one,
  # how many are connected (a game of one that asked would read the second port to count it).
  def self.game(players)
    VBlank.game("TAP #{players}", consoles: %i[ps1], players: players) do
      steps = (1..players).map { |player| var(:"steps#{player}", 0) }
      connected = var :connected, 1
      game_loop do
        steps.each.with_index(1) { |count, player| count.store!(count + 1) if held(:right, player: player) }
        connected.store!(players_connected) if players > 1
      end
    end
  end

  private def built(players) = self.class.game(players).build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)

  # The processor's share of a frame each routine that reads or keeps the buttons took, measured in
  # Beetle PSX (PS1Profiler), with a Multitap in for a game of four. The wait for the exchanges is not
  # among them: it is time the game had nothing to do (Pads#emit_await).
  private def button_shares(players)
    rows = built(players).profile(out: StringIO.new, settle: 10, frames: 20).runtime
    rows.select { |row| row.routine.to_s.match?(/\Art_pad|\Art_pads/) }.to_h { |row| [row.routine.to_s, row.share] }
  end

  # What the second, third and fourth players cost the processor. No retail game's Multitap routine
  # is documented that this could be held to, so the budget is the bytes psx-spx's Multitap exchange
  # takes: a pad's exchange is five bytes and the tap's thirty-five, so a game of four sends eight
  # times the bytes a game of one does, each handled by the pad's interrupt. Its budget is eight
  # times the one-pad game's whole cost, with the decoding of three more pads besides, priced at a
  # fifth of that cost each.
  def test_four_players_cost_less_than_eight_pads_exchanges
    one = button_shares(1).values.sum
    four = button_shares(4).values.sum
    budget = one * (8 + (3 / 5r))

    assert_operator four, :<, budget, "four players took #{four.round(5)} of a frame, the budget #{budget.to_f.round(5)}"
  end

  def test_a_game_of_one_reads_one_port
    run = game_player.hold(:right).run(self.class.game(1).program(console: :ps1), frames: 4)

    assert_operator run[:steps1], :>, 0
    assert_equal 1, run[:connected]
  end

  # The checked run plugs a tap in for a game of four, and the program agrees with the interpreter on
  # every pass: the third player alone is three players connected.
  def test_the_third_player_alone_moves_and_counts_three_connected
    run = game_player.hold(:p3_right).run(self.class.game(4).program(console: :ps1), frames: 6)

    assert_operator run[:steps3], :>, 0
    assert_equal 0, run[:steps2]
    assert_equal 3, run[:connected]
  end

  def test_every_player_is_read_through_the_tap_on_the_same_frame
    held = %i[right p2_right p3_right p4_right]
    run = game_player.input_each_frame { |frame| frame.between?(2, 5) ? held : [] }.run(self.class.game(4).program(console: :ps1), frames: 8)

    assert_equal [run[:steps1]] * 4, (1..4).map { |player| run[:"steps#{player}"] }
    assert_equal 4, run[:connected]
  end

  def test_a_player_who_joins_later_is_connected_from_then_on
    run = game_player.input_each_frame { |frame| frame == 4 ? [:p4_a] : [] }.run(self.class.game(4).program(console: :ps1), frames: 8)

    assert_equal 4, run[:connected]
  end

  # The Verifier plugs no tap in: Beetle PSX has a plain pad in the second port. The game finds no tap
  # and reads none of the third and fourth players.
  def test_with_no_multitap_the_third_and_fourth_players_hold_nothing
    rom = built(4)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 4, vars: rom.var_addresses)
    reader.step(6, keys: VBlank::IR::Buttons.mask(%i[p2_right p3_right p4_right]))

    assert_operator reader.var(:steps2), :>, 0, "the second port's own pad is the second player"
    assert_equal [0, 0], [reader.var(:steps3), reader.var(:steps4)]
    assert_equal 2, reader.var(:connected)
  end
end
