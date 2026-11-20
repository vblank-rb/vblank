# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "vblank/testing/cartridge_cache"

# A game's test helper sets once that the run builds its cartridges unmeasured
# (Testing.build_unmeasured), so a scene helper shared with the game's films, which calls
# `game.build_rom` itself, skips the measuring build in the tests and keeps measuring in a film.
# Measuring plays the cartridge in the emulator, so this is the Advance's run alone.
class TestBuildUnmeasured < Minitest::Test
  # Every test sets the run's setting, which the whole process shares.
  runs_on_the_main_ractor!

  MEASURING = "Building once to measure"

  def teardown
    VBlank::Cartridge::Game.unmeasured_builds = nil
  end

  private def dot_game
    VBlank.game("DOT", consoles: %i[gba]) do
      screen :bitmap
      game_loop do
        pixel 10, 10, :red
        wait_vblank
      end
    end
  end

  # The phases a build of +game+ printed, as a scene helper calls it.
  private def phases_of_build(game, **how)
    said = StringIO.new
    game.build_rom(out: StringIO.new, err: StringIO.new, progress: VBlank::Messages::Progress.to(said), **how)
    said.string
  end

  def test_a_build_measures_where_the_run_set_nothing
    assert_includes phases_of_build(dot_game), MEASURING
  end

  def test_a_run_set_unmeasured_builds_without_measuring
    VBlank::Testing.build_unmeasured

    refute_includes phases_of_build(dot_game), MEASURING
  end

  def test_a_build_asking_to_measure_still_measures
    VBlank::Testing.build_unmeasured

    assert_includes phases_of_build(dot_game, profile: true), MEASURING
  end

  # With the run's cache, the helper's build is kept: a later run, with a cache of its own on the same
  # folder, reads it rather than building.
  def test_a_build_with_the_runs_cache_is_read_back_by_a_later_run
    Dir.mktmpdir do |folder|
      game = dot_game
      VBlank::Testing.build_unmeasured(cache: VBlank::Testing::CartridgeCache.new(folder))
      first = game.build_rom(out: StringIO.new, err: StringIO.new)
      later = VBlank::Testing::CartridgeCache.new(folder)
      VBlank::Testing.build_unmeasured(cache: later)
      again = game.build_rom(out: StringIO.new, err: StringIO.new)
      said = StringIO.new
      later.report(said)

      # The report counts every ask on the folder since the later cache was made: the first build too.
      assert_match(/1 hits, 1 misses/, said.string)
      assert_equal first.buffer, again.buffer
      assert_equal game.build_rom(profile: false, out: nil, err: nil, from_cache: false).buffer, again.buffer
    end
  end
end
