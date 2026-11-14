# frozen_string_literal: true

require "test_helper"

# AN INDEX CHECKED ONCE on the Genesis (Lowering#index_checked_below?): a read or write of a list
# that always holds its capacity leaves out the check of an index already checked against a list no
# longer than it, while nothing can have changed the index. Each game here changes the index, or
# takes a way past the first check, between a check of a list of four and a read of a list of five
# past whose end the index then is: the game must stop at that read, naming that list, as the
# interpreter does.
#
# The cartridge is played by itself (Genesis::HeadlessRun), since a checked run plays the interpreter
# after it, which stops at that read whatever the cartridge did.
class TestGenesisIndexChecks < Minitest::Test
  private def assert_stops_at_medium(program)
    program = program.program(console: :genesis) if program.respond_to?(:build_rom)
    err = assert_raises(VBlank::IR::Backends::Reference::ProgramError) do
      VBlank::IR::Backends::Genesis::HeadlessRun.new.run(program, frames: 4)
    end
    assert_match(/medium/, err.message)
  end

  def test_an_index_written_after_its_check_is_checked_again
    assert_stops_at_medium(VBlank.game("INDEX CHECKS", consoles: %i[genesis]) do
      short = list :short, capacity: 4, full_of: 1
      medium = list :medium, capacity: 5, full_of: 1
      at = var :at, 2
      seen = var :seen, 0
      game_loop do
        seen = short[at]
        at = 6
        seen = medium[at]
      end
    end)
  end

  def test_an_index_a_routine_may_write_is_checked_again
    assert_stops_at_medium(VBlank.game("INDEX CHECKS", consoles: %i[genesis]) do
      short = list :short, capacity: 4, full_of: 1
      medium = list :medium, capacity: 5, full_of: 1
      at = var :at, 2
      seen = var :seen, 0
      func(:move_on) { at = 6 }
      game_loop do
        seen = short[at]
        call :move_on
        seen = medium[at]
      end
    end)
  end

  # The check on one side of a test is not made when the other side runs: one `if` with an `else`,
  # built as the tree holds one, since a game's own `else` is written as a second test.
  def test_the_other_side_of_a_test_checks_its_own_index
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :genesis))
    builder.instance_eval do
      list :short, capacity: 4, full_of: 1
      list :medium, capacity: 5, full_of: 1
      var :at, 6
      var :seen, 0
      ir = VBlank::IR::Build
      game_loop do
        sides = ir.if_(ir.binop(:==, ir.var_ref(:seen), ir.int(1)), ir.set(:seen, ir.list_get(:short, ir.var_ref(:at))))
        sides.else = ir.else_(ir.set(:seen, ir.list_get(:medium, ir.var_ref(:at))))
        record(sides)
      end
    end
    builder.finalize_program
    assert_stops_at_medium(builder.program)
  end

  # A loop's next turn checks the index it has moved on to.
  def test_each_turn_of_a_loop_checks_its_index
    assert_stops_at_medium(VBlank.game("INDEX CHECKS", consoles: %i[genesis]) do
      medium = list :medium, capacity: 5, full_of: 1
      long = list :long, capacity: 8, full_of: 1
      at = var :at, 0
      seen = var :seen, 0
      game_loop do
        at = 0
        while at < 8
          seen = medium[at] + long[at]
          at += 1
        end
      end
    end)
  end

  # ...and where the index stays inside every list, every pass plays as the interpreter's.
  def test_an_index_checked_once_reads_what_the_interpreter_reads
    game = VBlank.game("INDEX CHECKS", consoles: %i[genesis]) do
      short = list :short, capacity: 4, full_of: 1
      medium = list :medium, capacity: 5, full_of: 1
      long = list :long, capacity: 8, full_of: 1
      at = var :at, 1
      seen = var :seen, 0
      game_loop do
        long[at] = short[at] + 4
        seen = medium[at] + long[at]
        at = (at + 1) & 3
      end
    end
    game_player.run(game.program(console: :genesis), frames: 8)
  end
end
