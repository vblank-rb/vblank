# frozen_string_literal: true

require "test_helper"

# Which of the runtimes' features a game is built with (IR::Backends::RuntimeFeatures), from the
# steps the native lowering finds a run can reach (the JavaScript and Ruby lowerings are built on it),
# and how the features' hooks are checked as they are declared. What each lowering then writes is
# in test_runtime_features_in_*.rb, in each one's folder.
class TestRuntimeFeatures < Minitest::Test
  include VBlank::IR::Build

  Features = VBlank::IR::Backends::RuntimeFeatures

  private def feature(name, needed_by: %i[pixelate], hooks: [], after: [])
    Features::Feature.new(name: name, needed_by: needed_by, hooks: hooks, after: after)
  end

  private def steps_of(program) = VBlank::IR::Backends::Native::Lowering.new(program).reachable_steps

  def test_a_game_that_pixelates_is_built_with_pixelation_and_one_that_does_not_without
    pixelates = program(screen(:bitmap), pixelate(size: int(4)), halt)
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    assert_equal [:pixelation], Features.used_by(steps_of(pixelates)).map(&:name)
    assert_empty Features.used_by(steps_of(plain))
  end

  # A pixelate in a routine nothing calls never runs, so the game needs no pixelation.
  def test_a_step_no_run_reaches_needs_no_feature
    unreached = program(screen(:bitmap), func(:never, pixelate(size: int(4))), halt)

    assert_empty Features.used_by(steps_of(unreached))
  end

  def test_a_feature_comes_after_the_ones_it_names_whatever_their_names
    steps = steps_of(program(screen(:bitmap), pixelate(size: int(4)), halt))
    early = feature(:zebra)
    late = feature(:aardvark, after: [:zebra])

    assert_equal %i[zebra aardvark], Features.used_by(steps, among: [late, early]).map(&:name)
  end

  def test_a_hook_with_one_taker_at_most_refuses_a_second
    error = assert_raises(ArgumentError) do
      Features.refuse_wrong_hooks!([feature(:one, hooks: [:shown_row]), feature(:two, hooks: [:shown_row])])
    end

    assert_match(/one taker at most/, error.message)
  end

  def test_a_hook_no_runtime_has_is_refused
    error = assert_raises(ArgumentError) { Features.refuse_wrong_hooks!([feature(:odd, hooks: [:no_such_hook])]) }

    assert_match(/no_such_hook/, error.message)
  end
end
