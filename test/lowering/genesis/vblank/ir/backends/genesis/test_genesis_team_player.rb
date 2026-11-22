# frozen_string_literal: true

require "test_helper"
require "stringio"

# Four players on a Sega Genesis: the first pad, and three on Sega's Team Player in the second port
# (Genesis::Runtime::Frame#emit_team_player_read). A game finds the tap as it reads it; with a plain
# pad in the second port instead, that pad is the second player and the third and fourth hold
# nothing.
class TestGenesisTeamPlayer < Minitest::Test
  # A game for +players+: each player's steps counted while they hold right, and how many are
  # connected.
  def self.game(players)
    VBlank.game("TAP #{players}", consoles: %i[genesis], players: players) do
      steps = (1..players).map { |player| var(:"steps#{player}", 0) }
      connected = var :connected, 0
      game_loop do
        steps.each.with_index(1) { |count, player| count.store!(count + 1) if held(:right, player: player) }
        connected.store!(players_connected)
      end
    end
  end

  private def built(players) = self.class.game(players).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)

  # Every routine of the runtime that reads or keeps the buttons, each label's share of a frame in
  # lines of the picture, measured in Genesis Plus GX with a Team Player in for a game of four
  # (GenesisProfiler).
  private def button_lines(players)
    rows = built(players).profile(out: StringIO.new, settle: 10, frames: 20).runtime
    rows.select { |row| row.routine.to_s.match?(/pad|tap|button/) }.to_h { |row| [row.routine.to_s, row.share * 262] }
  end

  # What the third and fourth players cost. No retail game's Team Player routine is documented
  # that this could be held to, so the budget is the read plutiedev's "Sega multitap" gives for a
  # tap of four three-button pads, and what a game keeps of each pad it reads. That read is the
  # port read as a pad once, for its ID, two reads of the handshake that starts it (%0011, then
  # %1111), and fourteen nibbles: six of the header and two for each plug. Each read of the
  # handshake and each nibble is priced at what one nibble costs here (the rt_tap_read_*_wait and
  # _there labels, over the twelve the read here takes: it stops after the third plug, and takes
  # the handshake's answers from the ID read), the ID read at what the two-player game's second pad
  # read costs, and each of two more pads' keeping at what the two-player game spends a pad on all
  # its buttons' keeping besides the reads.
  def test_the_third_and_fourth_players_cost_less_than_plutiedevs_read_and_their_keeping
    two = button_lines(2)
    four = button_lines(4)
    nibble = four.select { |label, _| label.match?(/\Art_tap_read_.*_(wait|there)\z/) }.values.sum / 12
    pad_read = two.fetch("rt_second_buttons_now")
    keeping = (two.values.sum - two.fetch("rt_buttons_now") - pad_read) / 2
    budget = ((2 + 14) * nibble) + pad_read + (2 * keeping)
    extra = four.values.sum - two.values.sum

    assert_operator extra, :<, budget, "players 3 and 4 cost #{extra.round(2)} lines a frame, the budget #{budget.round(2)}"
  end

  def test_a_game_of_two_reads_no_tap
    refute(button_lines(2).keys.any? { |label| label.include?("tap") })
  end

  # The checked run plugs a tap in for a game of four, and the cartridge agrees with the
  # interpreter on every pass: the third player alone is three players connected.
  def test_the_third_player_alone_moves_and_counts_three_connected
    run = game_player.hold(:p3_right).run(self.class.game(4).program(console: :genesis), frames: 6)

    assert_operator run[:steps3], :>, 0
    assert_equal 0, run[:steps2]
    assert_equal 3, run[:connected]
  end

  def test_every_player_is_read_through_the_tap_on_the_same_frame
    held = %i[right p2_right p3_right p4_right]
    run = game_player.input_each_frame { |frame| frame.between?(2, 5) ? held : [] }.run(self.class.game(4).program(console: :genesis), frames: 8)

    assert_equal [run[:steps1]] * 4, (1..4).map { |player| run[:"steps#{player}"] }
    assert_equal 4, run[:connected]
  end

  # The Verifier plugs no tap in: Genesis Plus GX has a plain pad in the second port. The game
  # finds no tap and reads none of the third and fourth players.
  def test_with_no_team_player_the_third_and_fourth_players_hold_nothing
    rom = built(4)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 4, vars: rom.var_addresses)
    reader.step(6, keys: VBlank::IR::Buttons.mask(%i[p2_right p3_right p4_right]))

    assert_operator reader.var(:steps2), :>, 0, "the second port's own pad is the second player"
    assert_equal [0, 0], [reader.var(:steps3), reader.var(:steps4)]
    assert_equal 2, reader.var(:connected)
  end

  def test_with_no_team_player_and_nobody_at_the_second_pad_one_player_is_connected
    rom = built(4)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 4, vars: rom.var_addresses)
    reader.step(6, keys: VBlank::IR::Buttons.mask(%i[right]))

    assert_equal 1, reader.var(:connected)
    assert_equal [0, 0, 0], (2..4).map { |player| reader.var(:"steps#{player}") }
  end
end
