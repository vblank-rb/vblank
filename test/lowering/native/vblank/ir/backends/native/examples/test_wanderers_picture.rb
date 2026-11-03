# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "wanderers_tests"

# examples/wanderers.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded run: four players join one after another and wander off each their own
# way. Its variables match on every frame too. The four-player tests of WanderersTests
# (test/wanderers_tests.rb) play here as C as well.
class TestWanderersPicture < Minitest::Test
  include NativeComparison
  include WanderersTests

  # Player n joins on frame 10n and walks away from the middle for twenty frames; then nobody
  # holds anything.
  WAYS = { 1 => :up, 2 => :p2_right, 3 => :p3_left, 4 => :p4_down }.freeze
  RUN = Ractor.make_shareable((1..100).to_h do |frame|
    [frame, WAYS.filter_map { |player, way| way if (player * 10...(player * 10) + 20).cover?(frame) }]
  end)

  def test_wanderers_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Wanderers::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 100, buttons: RUN)

    assert_equal 4, (1..4).count { |player| last.variables[:"hue#{player}"] != Wanderers::NOT_PICKED },
                 "every player should have joined and been given a colour"
  end
end
