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
end
