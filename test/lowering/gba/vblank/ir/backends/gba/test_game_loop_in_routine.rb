# frozen_string_literal: true

require "test_helper"

# A game loop written inside a routine, which a scene calls and never leaves (GBA::Statements#emit_loop).
#
# The program's first loop is the game loop whose body the quick memory may hold as a routine of its
# own. Another loop is lowered where it is written: were it a call to that routine, the cartridge
# would run the first loop's body there instead of its own.
class TestGameLoopInRoutine < Minitest::Test
  # A title that counts six passes, then a play scene whose routine runs a loop of its own for good,
  # drawing a dot a pass along a row, so how far the row reaches says how many passes it ran.
  private def scene_with_own_loop
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      t = 0
      dots = 0
      where = 0
      func(:play_work) do
        game_loop do
          draw_rect_at (dots % 100) * 2, 20, 2, 2, :white
          dots += 1
        end
      end
      scene(:title) { draw_rect_at t * 2, 10, 2, 2, :red }
      scene(:play) { call :play_work }
      game_loop do
        t += 1
        where = 1 if t == 6
        call({ 0 => :title, 1 => :play }, number: :where)
      end
    end
    builder.finalize_program
    builder.program
  end

  # The pictures are not compared: the check that lines a picture up with the interpreter counts
  # the first loop's passes, and this game leaves that loop for good. The numbers are, read after
  # the cartridge's frame and the interpreter's on either side of it, since a frame of the
  # cartridge can be read before its pass has run.
  def test_a_loop_in_a_routine_runs_its_own_body_on_the_cartridge
    program = scene_with_own_loop
    v = assert_emulator_loads_rom(assemble_rom(program, name: "OWNLOOP"), frames: FRAMES)
    before, after = [FRAMES - 1, FRAMES].map { |frames| Reference.new.run(program, frames: frames) }

    assert_equal after[:t], v.var(:t), "the title's loop stopped where the interpreter's did"
    assert_includes before[:dots]..after[:dots], v.var(:dots), "the routine's own loop ran a pass a frame"
  end

  FRAMES = 20
end
