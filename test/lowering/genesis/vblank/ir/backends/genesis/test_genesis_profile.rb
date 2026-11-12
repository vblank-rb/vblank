# frozen_string_literal: true

require "test_helper"
require "stringio"

# A Genesis cartridge measured as it runs (Diagnostics::GenesisProfiler): how many frames each pass
# took, and which code took them.
class TestGenesisProfile < Minitest::Test
  # A routine of the game's that does most of the work there is.
  BUSY = VBlank.game("BUSY", consoles: %i[genesis]) do
    total = 0
    func(:hard_work) { repeat(20) { total += 3 } }
    game_loop { call :hard_work }
  end

  def test_the_report_says_where_the_time_went_and_what_was_left
    out = StringIO.new
    result = BUSY.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false).profile(out: out, frames: 20)

    assert_equal 20, result.passes
    assert_operator result.idle_share, :>, 0.1
    assert_operator result.idle_share, :<, 1
    assert_operator result.fewest_lines_spare, :>, 10
    assert_operator result.fewest_lines_spare, :<, 262
    assert_match(/hard_work/, result.game.first.routine)
    assert_match(/lines to spare/, out.string)
  end

  # A routine with a loop and a test in it has places inside it that its jumps go to. Its time is
  # all under the routine's name, so a routine that is most of a pass is listed as most of it.
  def test_a_routine_is_listed_once_whatever_places_its_loops_and_tests_have
    game = VBlank.game("BRANCHY", consoles: %i[genesis]) do
      total = var :total, 0
      func(:hard_work) do
        repeat(20) do
          if total > 30
            total -= 7
          else
            total += 3
          end
        end
      end
      game_loop { call :hard_work }
    end
    result = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 20)
    routines = result.game.map(&:routine)

    assert_equal routines.uniq, routines
    assert_equal 1, routines.grep(/hard_work/).length, "listed: #{routines.inspect}"
    assert_equal 1, routines.grep(/\Amain/).length, "listed: #{routines.inspect}"
    assert_operator result.game.first.share, :>, 0.5 * (1 - result.idle_share), "the routine is most of what the game spent"
  end
end
