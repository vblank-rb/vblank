# frozen_string_literal: true

require "test_helper"

# A CARTRIDGE BUILD'S TRIES (Backends::BuildTries), walked over a made-up build whose tries need
# room: each try fits when its settings give at least the room it asks for, and stops with an
# error naming what it is short of otherwise. The consoles' own builds are held to the cartridges
# they make in their own folders; this is the order the tries go in.
class TestBuildTries < Minitest::Test
  BuildTries = VBlank::IR::Backends::BuildTries

  Settings = Data.define(:tiles, :colors, :spare) do
    def self.first = new(tiles: 1, colors: 1, spare: false)
  end

  class TooFewTiles < StandardError; end
  class TooFewColors < StandardError; end

  # A try that fits where +settings+ give +tiles+ and +colors+, and is the settings it fit with.
  private def fit_needing(tiles:, colors:, spare_fits: true)
    lambda do |try|
      settings = try.settings
      raise TooFewColors if settings.colors < colors
      raise TooFewTiles if settings.tiles < tiles
      raise TooFewTiles if settings.spare && !spare_fits

      settings
    end
  end

  private def more_room(error, try)
    settings = try.settings
    case error
    when TooFewTiles then settings.with(tiles: settings.tiles + 1) if settings.tiles < 4
    when TooFewColors then settings.with(colors: settings.colors + 1) if settings.colors < 4
    end
  end

  private def build(tries, fit, **steps)
    tries.run(next_settings: ->(error, try) { more_room(error, try) }, **steps) { |try| fit.call(try) }
  end

  def test_a_build_that_fits_at_first_takes_one_try
    tries = BuildTries.new("Test", Settings.first)

    assert_equal Settings.first, build(tries, fit_needing(tiles: 1, colors: 1))
    assert_equal 1, tries.count
  end

  # Room found for the colours is kept when the tiles run out next.
  def test_each_try_keeps_what_the_tries_before_it_found
    tries = BuildTries.new("Test", Settings.first)

    assert_equal Settings.new(tiles: 2, colors: 3, spare: false), build(tries, fit_needing(tiles: 2, colors: 3))
    assert_equal 4, tries.count
    assert_equal [TooFewColors, TooFewColors, TooFewTiles, NilClass], tries.tries.map { |try| try.stopped_by.class }
  end

  def test_an_error_no_step_answers_stands
    tries = BuildTries.new("Test", Settings.first)

    assert_raises(TooFewTiles) { build(tries, fit_needing(tiles: 9, colors: 1)) }
    assert_equal 4, tries.count
  end

  # An attempt that does not work gives the build back to where it was made, which carries on
  # with what it said to try instead.
  def test_an_attempt_that_does_not_fit_goes_back
    tries = BuildTries.new("Test", Settings.first)
    attempted = false
    step = lambda do |error, try|
      next more_room(error, try) if attempted || !error.is_a?(TooFewTiles)

      attempted = true
      BuildTries::Attempt.new(settings: try.settings.with(spare: true), otherwise: try.settings.with(tiles: 2),
                              given_up_on: [TooFewTiles])
    end
    fit = fit_needing(tiles: 2, colors: 1, spare_fits: false)

    assert_equal Settings.new(tiles: 2, colors: 1, spare: false), tries.run(next_settings: step) { |try| fit.call(try) }
  end

  # A better try after one that fit is kept only if it fits too, once no step can help it.
  def test_a_better_try_that_does_not_fit_leaves_the_one_that_did
    tries = BuildTries.new("Test", Settings.first)
    better = ->(try, _) { BuildTries::Attempt.new(settings: try.settings.with(spare: true), given_up_on: [TooFewTiles]) unless try.settings.spare }

    assert_equal Settings.first, build(tries, fit_needing(tiles: 1, colors: 1, spare_fits: false), better: better)
    assert_equal [NilClass, TooFewTiles, TooFewTiles, TooFewTiles, TooFewTiles], tries.tries.map { |try| try.stopped_by.class }
  end

  def test_a_better_try_that_fits_is_the_build
    tries = BuildTries.new("Test", Settings.first)
    better = ->(try, _) { BuildTries::Attempt.new(settings: try.settings.with(spare: true), given_up_on: [TooFewTiles]) unless try.settings.spare }

    assert_equal Settings.new(tiles: 1, colors: 1, spare: true), build(tries, fit_needing(tiles: 1, colors: 1), better: better)
  end

  def test_steps_a_measurement_rules_out_are_passed_over
    following = ->(step) { step < 10 ? step + 1 : nil }

    assert_equal 7, BuildTries.first_step_not_ruled_out(1, following: following) { |step| step < 7 }
    assert_nil BuildTries.first_step_not_ruled_out(1, following: following) { true }
  end
end
