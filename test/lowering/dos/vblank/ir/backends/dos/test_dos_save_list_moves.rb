# frozen_string_literal: true

require "save_list_move_tests"

# A whole list moved to or from save memory on a PC, an item at a time as the steps stand for
# (IR::SaveListMoves), held to the interpreter (SaveListMoveTests).
class TestDOSSaveListMoves < Minitest::Test
  include SaveListMoveTests

  private def moved_on = :dos
  private def checked_run = VBlank::IR::Backends::DOS::CheckedRun
end
