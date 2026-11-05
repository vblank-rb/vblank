# frozen_string_literal: true

require "test_helper"
require "stringio"

# What the PlayStation spends on a place's faces that lie wholly outside the window they are drawn
# through, measured in Beetle PSX (Diagnostics::PS1Profiler). A game of rooms draws each room through
# the window its doorway makes, and the faces round the doorway, the walls beside the viewer among
# them, lie outside it. Such a face is passed over once it is cut at the near limit, before it is
# tested for which way it faces or sent to the graphics chip (IR::PlaceDrawing::OUTCODE_EDGES).
class TestPS1PlaceWindowPace < Minitest::Test
  STRIPS = 24

  # A wall down the viewer's left side, from a whole behind them to six ahead, in STRIPS strips one
  # above the next, so the near limit cuts every strip. Seen straight on, the wall reaches from past
  # the screen's left edge to x 100. The setting window: :whole draws it four times a pass through the
  # whole screen; :right through a window from x 140 on, which the wall lies wholly left of.
  WALL = VBlank.game("STRIPS BESIDE", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image :tile, width: 8, height: 8, data: Array.new(64) { |k| k.even? ? 0x7FFF : 0x001F }
    place :side do
      STRIPS.times do |k|
        low = -1.0 + (2.0 * k / STRIPS)
        high = -1.0 + (2.0 * (k + 1) / STRIPS)
        face point(-1.0, high, -1.0), point(-1.0, high, 6.0), point(-1.0, low, 6.0), point(-1.0, low, -1.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
      end
    end
    window = setting(:window, :right) == :whole ? [0, 0, 240, 160] : [140, 0, 240, 160]
    eye = viewer :eye, at: [0.0, 0.0, 0.0]
    game_loop do
      clear_screen :black
      4.times { draw_place :side, seen_by: eye, window: window }
    end
  end

  # Faces the near limit cuts are tested too, on the corners the cut made: drawn through a window they
  # lie wholly outside of, the strips cost under a third of drawing them. Tested before the cut and
  # only on corners in front of the limit, none of them was passed over, and they cost more than that.
  def test_faces_cut_at_the_near_limit_outside_the_window_cost_under_a_third_of_drawing_them
    outside = busy_frames(profile(window: :right))
    drawn = busy_frames(profile(window: :whole))

    assert_operator outside, :<, drawn / 3.0
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(**settings)
    rom = WALL.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 48)
  end
end
