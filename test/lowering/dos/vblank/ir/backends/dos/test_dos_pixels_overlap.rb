# frozen_string_literal: true

require "test_helper"

# WHETHER TWO PICTURES' DRAWN PIXELS TOUCH, on a PC (Runtime::Overlap), held to the interpreter. What
# `overlaps?` means is in test/all/vblank/dsl/test_pixel_perfect_collision.rb, which this run plays; these
# are what the routine can get wrong of its own: each edge one way and the other, places far apart enough
# to pass 32 bits if subtracted carelessly, a pose counted back from the last, one that names no picture,
# and an overlap asked while working out another's place.
class TestDOSPixelsOverlap < Minitest::Test
  include VBlank::IR::Build

  DOS = VBlank::IR::Backends::DOS

  # A 5x3 picture drawn only down its first and last columns, and a 2x2 drawn all over.
  RIM = [1, 0, 0, 0, 1] * 3
  DOT = [1, 1, 1, 1].freeze

  private def pictures
    [bitmap(:rim, width: 5, height: 3, pixels: RIM.map { |drawn| drawn == 1 ? 0x7FFF : 0 }.pack("v*"), transparent: 0),
     bitmap(:dot, width: 2, height: 2, pixels: DOT.map { 0x001F }.pack("v*")),
     bitmap(:hollow, width: 3, height: 1, pixels: [0, 0, 0].pack("v*"), transparent: 0)]
  end

  private def overlap(b_x, b_y, a_pose: 0, b_pose: 0, a_x: 10, a_y: 20)
    pixels_overlap(a_poses: %i[rim hollow], a_pose: int(a_pose), a_x: int(a_x), a_y: int(a_y),
                   b_poses: %i[dot rim], b_pose: int(b_pose), b_x: b_x.is_a?(Integer) ? int(b_x) : b_x,
                   b_y: b_y.is_a?(Integer) ? int(b_y) : b_y)
  end

  private def checked(*statements)
    DOS::CheckedRun.new.run(program(screen(:bitmap), *pictures, *statements, halt, console: :dos), frames: 1)
  end

  # The dot laid at every place round and over the rim picture, each answer kept in a list: touching the
  # drawn columns, the hollow middle, and one pixel past each edge.
  def test_every_place_round_a_picture_answers_as_the_interpreter
    places = (7..16).to_a.product((17..23).to_a)
    run = checked(list_new(:hits, places.size, width: :byte),
                  *places.map { |x, y| list_push(:hits, overlap(x, y)) })

    hits = run.list(:hits)
    assert_equal places.size, hits.size
    assert_includes hits, 1
    assert_includes hits, 0
  end

  # Places a whole number range apart, where the second's less the first's passes what 32 bits hold, and a
  # second side counted back from its last picture, which here is the rim over the rim.
  def test_places_far_apart_and_a_pose_counted_back
    run = checked(set(:far_right, overlap(2_000_000_000, 20, a_x: -2_000_000_000)),
                  set(:far_left, overlap(-2_000_000_000, 20, a_x: 2_000_000_000)),
                  set(:far_down, overlap(10, -2_147_483_648, a_y: 2_147_483_647)),
                  set(:counted_back, overlap(14, 20, b_pose: -1)),
                  set(:nothing_drawn, overlap(10, 20, a_pose: 1)))

    assert_equal [0, 0, 0, 1, 0], %i[far_right far_left far_down counted_back nothing_drawn].map { |name| run[name] }
  end

  # The second side's x worked out from another overlap, so the first is asked while the second's numbers
  # are part made.
  def test_an_overlap_asked_inside_another
    inner = overlap(10, 20)
    run = checked(set(:outer, overlap(binop(:+, int(13), binop(:*, inner, int(1))), 21)))

    assert_equal 1, run[:outer]
  end

  # A pose that names none of a side's pictures stops the game, in the words of a sprite with no such picture.
  def test_a_pose_naming_no_picture_stops_the_game
    game = program(screen(:bitmap), *pictures, set(:hit, overlap(10, 20, b_pose: 2)), halt, console: :dos)
    error = assert_raises(VBlank::IR::ProgramError) { DOS::HeadlessRun.new.run(game, frames: 1) }

    assert_match(/picture 2 of its 2/, error.message)
  end
end
