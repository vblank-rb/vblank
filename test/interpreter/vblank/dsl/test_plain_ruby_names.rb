# frozen_string_literal: true

require "test_helper"

# What LocalNames tells the rewriter about a file of VBlank's own, which no test can write as a
# game: there a method called on nothing is VBlank's, but `call` of a routine still runs game code.
# It plays no game, so it sits with the run whose player is the interpreter rather than in every
# lowering's.
class TestPlainRubyNames < Minitest::Test
  private def kept_across?(line_between)
    source = "proc do\n  packed = list(:packed)\n  at = var(:at, 0)\n  game_loop do\n    flags = packed[at]\n    " \
             "#{line_between}\n    seen = flags\n  end\nend\n"
    loop_block = Prism.parse(source).value.statements.body.first.block
    loop_lines = loop_block.body.body.last.block.body.body
    names = VBlank::DSL::PlainRuby::LocalNames.new(loop_block, library_file: true)
    !names.copy_kept(loop_lines.first).nil?
  end

  def test_a_call_of_a_routine_in_vblanks_own_file_keeps_a_local_read_before_it
    assert kept_across?("call :step_on")
    assert kept_across?("case_var :mode")
    assert kept_across?("start_over :level")
  end

  def test_a_node_made_in_vblanks_own_file_keeps_nothing
    refute kept_across?("Build.call(:step_on)")
    refute kept_across?("draw_frame(at)")
  end
end
