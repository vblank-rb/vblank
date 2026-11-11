# frozen_string_literal: true

require "save_list_move_tests"

# The Super Nintendo's own routines for a whole list moved to or from save memory (Runtime::Saving
# #emit_list_moves), held to the interpreter (SaveListMoveTests).
class TestSNESSaveListMoves < Minitest::Test
  include SaveListMoveTests

  private def moved_on = :snes
  private def checked_run = VBlank::IR::Backends::SNES::CheckedRun
end
