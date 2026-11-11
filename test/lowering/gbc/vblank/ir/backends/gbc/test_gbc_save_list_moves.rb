# frozen_string_literal: true

require "save_list_move_tests"

# The Color's own routines for a whole list moved to or from save memory (Runtime::Lists
# #emit_save_moves), held to the interpreter (SaveListMoveTests).
class TestGBCSaveListMoves < Minitest::Test
  include SaveListMoveTests

  private def moved_on = :gbc
  private def checked_run = VBlank::IR::Backends::GBC::CheckedRun
end
