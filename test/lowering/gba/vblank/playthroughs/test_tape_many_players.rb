# frozen_string_literal: true

require "test_helper"

# A TAPE WRITES ANY PLAYER'S BUTTONS BY NUMBER, :p3_right as :p2_right, and they reach that
# player on a way that plays more players than a console seats: the interpreter, and the game as
# Ruby, whose runtime is handed a list of buttons a player at a time. Each step of the tape is
# played the way a tape plays it (Tape#play), its buttons as one number (Playthrough.key_mask)
# read back as names by the way that plays it (LoweredGame).
class TestTapeManyPlayers < Minitest::Test
  runs_on_the_main_ractor! # the game as Ruby plays in another process, which hangs inside a Ractor

  Tape = VBlank::Playthroughs::Tape
  Playthrough = VBlank::Playthroughs::Playthrough
  LoweredGame = VBlank::Playthroughs::LoweredGame

  private def three_movers
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      first = var :first, 0
      third = var :third, 0
      connected = var :connected, 0
      game_loop do
        first += 1 if held(:right)
        third += 1 if held(:right, player: 3)
        connected.store!(players_connected)
      end
    end
    b.finalize_program
    b.program
  end

  private def tape
    Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: ANYTHING 0x00000000
      starts from: power-on

      2 -
      4 p3_right
      2 p2_a
      2 -
    TAPE
  end

  def test_a_tape_holds_the_third_players_buttons
    %w[interpreter ruby].each do |way|
      game = LoweredGame.new(three_movers, way)
      tape.steps.each { |step| game.step(step.frames, keys: Playthrough.key_mask(step.buttons)) }

      assert_equal 0, game.var(:first), way
      assert_operator game.var(:third), :>=, 3, way
      assert_equal 3, game.var(:connected), way
      game.finish
    end
  end

  def test_a_tape_with_another_players_buttons_reads_back_as_written
    assert_equal tape, Tape.parse(tape.to_s)
    assert_equal [:p3_right], tape.steps[1].buttons
  end

  def test_a_tape_naming_a_player_past_the_most_is_refused_in_plain_words
    error = assert_raises(StandardError) do
      Tape.parse("vblank tape 1\nrecorded on: X 0x00000000\nstarts from: power-on\n\n2 p17_a\n")
    end

    assert_match(/player's number/, error.message)
  end
end
