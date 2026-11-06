# frozen_string_literal: true

# A ROUTINE CALLED FROM INSIDE AN AREA has its drawing held to that area, on a console whose build
# keeps the area in memory as the game runs (Console::Description#area_clips_called_routines). The
# interpreter clips it there, and each such console's cartridge is checked against it. Played by
# test/console/gbc/vblank/builder/test_called_routine_area_on_the_color.rb,
# test/console/snes/vblank/builder/test_called_routine_area_on_the_super_nintendo.rb,
# test/console/genesis/vblank/builder/test_called_routine_area_on_the_genesis.rb and
# test/console/ps1/vblank/builder/test_called_routine_area_on_the_playstation.rb. The Advance's build
# refuses the game (test/all/vblank/ir/guardrails/test_ir_guardrail_call_inside_area.rb).
module CalledRoutineAreaTests
  # A routine that fills most of the screen red and puts a blue square across the area's top left
  # corner, called from inside an area 40 wide and 30 high whose corner is at (20, 20).
  private def routine_called_inside_an_area
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      image :square, width: 8, height: 8, data: Array.new(64, :blue)
      func :paint do
        fill_rect 0, 0, 120, 100, :red
        blit :square, 16, 16
      end
      game_loop do
        clear_screen :black
        inside(20, 20, 40, 30) { call :paint }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_routine_called_inside_an_area_draws_only_inside_it
    shown = game_player.run(routine_called_inside_an_area, frames: 4).screen

    assert_equal VBlank::Testing.shown(:red), shown.pixel(30, 30), "the fill inside the area"
    assert_equal VBlank::Testing.shown(:blue), shown.pixel(21, 21), "the square's part inside the area"
    assert_equal VBlank::Testing.shown(:black), shown.pixel(18, 18), "nothing of the square outside the area"
    assert_equal VBlank::Testing.shown(:black), shown.pixel(70, 30), "nothing of the fill past the right edge"
    assert_equal VBlank::Testing.shown(:black), shown.pixel(30, 60), "nothing of the fill past the bottom edge"
  end
end
