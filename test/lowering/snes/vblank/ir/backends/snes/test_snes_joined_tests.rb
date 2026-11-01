# frozen_string_literal: true

require "test_helper"

# A list read past its end stops the game, even on the right of a join the left has decided.
class TestSNESJoinedTests < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_a_list_read_on_the_right_still_stops_the_game
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      xs = list :xs, capacity: 4, width: :byte
      xs.push 1
      n = var :n, 3
      a = var :a, 1
      hits = var :hits, 0
      game_loop { hits += 1 if (a == 2) & (xs[n] == 0) }
    end
    b.finalize_program
    error = assert_raises(VBlank::IR::ProgramError) { SNES::HeadlessRun.new.run(b.program, frames: 5) }

    assert_match(/out of range/, error.message)
  end
end
