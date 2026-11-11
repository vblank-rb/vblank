# frozen_string_literal: true

require "test_helper"
require "stringio"

# What the PlayStation spends on a shape drawn where the game puts it (`draw_place ..., at:`), measured
# in Beetle PSX (Diagnostics::PS1Profiler). A game drawing its robots round the player draws most of
# them behind or beside the viewer at any moment; a shape there draws nothing, so it is passed over
# before any of its points is turned. One in view costs what the same faces cost in a place drawn
# where it was declared.
class TestPS1ShapeRingPace < Minitest::Test
  SLICES = 12
  BANDS = 5
  COPIES = 8

  # Where the COPIES balls stand when they are all in view: spread across it, nine wholes ahead.
  AHEAD = Array.new(COPIES) { |k| [(k - 3.5) * 1.5, 0.0, 9.0] }

  # A ball one whole across round +middle+, of SLICES slices and BANDS bands (fans at the poles,
  # four-cornered faces between): 50 points and 60 faces, the size of a robot. Declared in +place+, the
  # block of a `place` it is called from.
  def self.declare_ball(place, middle, picture)
    mx, my, mz = middle
    place.instance_eval do
      top = point(mx, my + 0.5, mz)
      bottom = point(mx, my - 0.5, mz)
      rings = (1...BANDS).map do |band|
        across = Math.sin(Math::PI * band / BANDS) * 0.5
        up = Math.cos(Math::PI * band / BANDS) * 0.5
        Array.new(SLICES) do |slice|
          turn = 2 * Math::PI * slice / SLICES
          point(mx + (across * Math.cos(turn)), my + up, mz + (across * Math.sin(turn)))
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
  end

  # One ball, drawn COPIES times a pass. The setting spots: decides where, with the viewer at the
  # middle looking ahead along z: :none draws none, :ahead spreads them across the view nine wholes
  # ahead, :behind puts them nine wholes behind, and :beside two wholes ahead and nine to either
  # side, past the view's edges.
  RING = VBlank.game("BALLS ROUND", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image :tile, width: 8, height: 8, data: Array.new(64) { |k| k.even? ? 0x7FFF : 0x001F }
    place(:ball) { TestPS1ShapeRingPace.declare_ball(self, [0.0, 0.0, 0.0], { picture: :tile }) }
    spots = case setting(:spots, :none)
            when :ahead then AHEAD
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

  # THE SAME EIGHT BALLS IN VIEW, TWO WAYS, seen by a viewer that moves a little every pass as a
  # player's does: with the setting balls: :at_spots, one ball drawn at each of AHEAD; with
  # :declared, eight declared in one place where those stand, drawn once; with :none, nothing.
  #
  # THE VIEWER MUST MOVE. A place drawn where it was declared, by a viewer that has not moved since
  # the pass before, reads the points that pass turned and turns none (IR::PlaceDrawing, "HANDED
  # OVER UNCHANGED"); a shape at a spot turns its points for every drawing. Measured with the viewer
  # standing still, the declared place costs well under the shapes at spots, and all of the
  # difference is turning it never did. No game holds its viewer still.
  IN_VIEW = VBlank.game("BALLS IN VIEW", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image :tile, width: 8, height: 8, data: Array.new(64) { |k| k.even? ? 0x7FFF : 0x001F }
    place(:ball) { TestPS1ShapeRingPace.declare_ball(self, [0.0, 0.0, 0.0], { picture: :tile }) }
    place(:balls) { AHEAD.each { |middle| TestPS1ShapeRingPace.declare_ball(self, middle, { picture: :tile }) } }
    balls = setting(:balls, :none)
    eye = viewer :eye, at: [0.0, 0.0, 0.0]
    step = var :step, 0.01
    game_loop do
      clear_screen :black
      eye.move :left, by: step
      every(30) { step.store!(step * -1) }
      AHEAD.each { |spot| draw_place :ball, seen_by: eye, at: spot } if balls == :at_spots
      draw_place :balls, seen_by: eye if balls == :declared
    end
  end

  # Balls behind the viewer, or beside it past the view's edges, cost under a tenth of what the same
  # balls cost drawn in view.
  def test_shapes_wholly_out_of_view_cost_under_a_tenth_of_shapes_in_view
    none = busy_frames(profile(RING, spots: :none))
    shown = busy_frames(profile(RING, spots: :ahead)) - none

    %i[behind beside].each do |spots|
      hidden = busy_frames(profile(RING, spots: spots)) - none

      assert_operator hidden, :<, shown / 10.0, "balls #{spots}: #{hidden.round(3)} frames a pass, in view #{shown.round(3)}"
    end
  end

  # A shape at a spot turns its own points and is tested for being in view; a place drawn where it
  # was declared does neither for each ball. That is all the difference there is: a few hundredths.
  def test_shapes_in_view_cost_what_the_same_faces_cost_declared_where_they_stand
    none = busy_frames(profile(IN_VIEW, balls: :none))
    at_spots = busy_frames(profile(IN_VIEW, balls: :at_spots)) - none
    declared = busy_frames(profile(IN_VIEW, balls: :declared)) - none

    assert_operator at_spots, :<, declared * 1.15,
                    "at spots #{at_spots.round(3)} frames a pass, declared where they stand #{declared.round(3)}"
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(game, **settings)
    rom = game.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 48)
  end
end
