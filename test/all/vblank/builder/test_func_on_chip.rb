# frozen_string_literal: true

require "test_helper"

# `on_chip: true` says where a routine runs on a cartridge with a chip that can run it. On every
# other console and lowering, and on the interpreter, the word changes nothing, whatever the routine
# holds: a step the chip could not do is refused only where there is a chip.
class TestFuncOnChip < Minitest::Test
  private def played(on_chip)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      total = var :total, 1
      cells = list :cells, capacity: 4, full_of: 3
      func :work, on_chip: on_chip do
        total.store!((total * 3) + cells[1])
        fill_rect 0, 0, 16, 8, :green
      end
      game_loop { call :work }
    end
    builder.finalize_program
    game_player.run(builder.program, frames: 6)
  end

  def test_the_word_changes_nothing_here
    with_word = played(true)
    without = played(nil)

    assert_equal without[:total], with_word[:total]
    assert_operator with_word[:total], :>, 1, "the routine ran"
    assert_equal without.screen.pixel(1, 1), with_word.screen.pixel(1, 1)
  end
end
