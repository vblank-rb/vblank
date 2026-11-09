# frozen_string_literal: true

require "test_helper"
require "stringio"

# What the PlayStation spends on a shape drawn where the game puts it (`draw_place ..., at:`) when
# the spot is wholly out of view, measured in Beetle PSX (Diagnostics::PS1Profiler). A game drawing
# its robots round the player draws most of them behind or beside the viewer at any moment; a
# shape there draws nothing, so it is passed over before any of its points is turned.
class TestPS1ShapeRingPace < Minitest::Test
  SLICES = 12
  BANDS = 5
  COPIES = 8

  # A ball one whole across, of SLICES slices and BANDS bands (fans at the poles, four-cornered
  # faces between): 50 points and 60 faces, the size of a robot. The setting spots: decides where
  # the COPIES balls are drawn each pass, with the viewer at the middle looking ahead along z:
  # :none draws none, :ahead spreads them across the view nine wholes ahead, :behind puts them
  # nine wholes behind, and :beside two wholes ahead and nine to either side, past the view's
  # edges.
  RING = VBlank.game("BALLS ROUND", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image :tile, width: 8, height: 8, data: Array.new(64) { |k| k.even? ? 0x7FFF : 0x001F }
    picture = { picture: :tile }
    place :ball do
      top = point(0.0, 0.5, 0.0)
      bottom = point(0.0, -0.5, 0.0)
      rings = (1...BANDS).map do |band|
        across = Math.sin(Math::PI * band / BANDS) * 0.5
        up = Math.cos(Math::PI * band / BANDS) * 0.5
        Array.new(SLICES) do |slice|
          turn = 2 * Math::PI * slice / SLICES
          point(across * Math.cos(turn), up, across * Math.sin(turn))
        end
      end
      SLICES.times do |slice|
        following = (slice + 1) % SLICES
        face top, rings.first[following], rings.first[slice], **picture, on_picture: [[4, 0], [8, 8], [0, 8]]
        rings.each_cons(2) do |upper, lower|
          face upper[slice], upper[following], lower[following], lower[slice], **picture,
               on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
        end
        face bottom, rings.last[slice], rings.last[following], **picture, on_picture: [[0, 0], [8, 0], [4, 8]]
      end
    end
    spots = case setting(:spots, :none)
            when :ahead then Array.new(COPIES) { |k| [(k - 3.5) * 1.5, 0.0, 9.0] }
            when :behind then Array.new(COPIES) { |k| [(k - 3.5) * 1.5, 0.0, -9.0] }
            when :beside then Array.new(COPIES) { |k| [k.even? ? -9.0 : 9.0, (k - 3.5) * 0.5, 2.0] }
            else []
            end
    eye = viewer :eye, at: [0.0, 0.0, 0.0]
    game_loop do
      clear_screen :black
      spots.each { |spot| draw_place :ball, seen_by: eye, at: spot }
    end
  end

  # Balls behind the viewer, or beside it past the view's edges, cost under a tenth of what the same
  # balls cost drawn in view.
  def test_shapes_wholly_out_of_view_cost_under_a_tenth_of_shapes_in_view
    none = busy_frames(profile(spots: :none))
    shown = busy_frames(profile(spots: :ahead)) - none

    %i[behind beside].each do |spots|
      hidden = busy_frames(profile(spots: spots)) - none

      assert_operator hidden, :<, shown / 10.0, "balls #{spots}: #{hidden.round(3)} frames a pass, in view #{shown.round(3)}"
    end
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(**settings)
    rom = RING.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 48)
  end
end
