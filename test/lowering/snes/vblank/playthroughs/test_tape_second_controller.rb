# frozen_string_literal: true

require "test_helper"

# A TAPE WRITES THE SECOND CONTROLLER'S BUTTONS AS :p2_start, and they reach the cartridge's
# second controller.
class TestTapeSecondController < Minitest::Test
  Tape = VBlank::Playthroughs::Tape

  private def joining_game
    VBlank.build("JOINS", console: :snes, out: StringIO.new, err: StringIO.new) do
      joins = var :joins, 0
      firsts = var :firsts, 0
      game_loop do
        joins += 1 if pressed(:start, player: 2)
        firsts += 1 if pressed(:start)
      end
    end
  end

  def test_a_tape_holds_buttons_on_the_second_controller
    tape = Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: ANYTHING 0x00000000
      starts from: power-on

      6 -
      2 p2_start
      6 -
    TAPE
    played = tape.play(joining_game)

    assert_equal 1, played.game.var(:joins)
    assert_equal 0, played.game.var(:firsts)
    assert_equal tape, Tape.parse(tape.to_s)
  end
end
