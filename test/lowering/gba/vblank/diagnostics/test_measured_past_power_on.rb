# frozen_string_literal: true

require "test_helper"

require "stringio"

# POWER-ON IS NOT PLAY. A game looks its saves over once, before its first pass, and a big record
# takes the console many frames to read. Nobody sees that again until the console is turned off,
# so the frames a build measures start after it, however long it takes: a scene told it runs at
# half speed has to be a scene that does, and not the first moments after the switch.
class TestMeasuredPastPowerOn < Minitest::Test
  Profiler = VBlank::Diagnostics::Profiler
  LOOKING_OVER = VBlank::Messages::MadeNames.make(:save_record, record: :file, piece: :scan)

  # Seven copies of a record of five thousand bytes, and a scene with almost nothing to do.
  private def large_saves_rom
    game = VBlank.game "LONGSTART", consoles: %i[gba] do
      screen :bitmap
      keepsake = list :keepsake, capacity: 5000, width: :byte
      save_data :file, copies: 7 do
        keep keepsake
      end
      var :where, 0
      scene(:play) { clear_screen :black }
      game_loop do
        case_var(:where) { when_val 0, :play }
      end
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
  end

  # Slow for its first hundred passes and quick for ever after.
  private def slow_at_first_rom
    game = VBlank.game "SLOWFIRST", consoles: %i[gba] do
      screen :bitmap
      var :where, 0
      passes = var :passes, 0
      scene(:play) do
        passes += 1
        repeat(60_000) { pixel 1, 1, :red } if passes < 100
      end
      game_loop do
        case_var(:where) { when_val 0, :play }
      end
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
  end

  def setup
    require_emulator!
  end

  def test_a_scene_is_not_told_it_is_slow_for_what_power_on_did
    survey = Profiler.survey_scenes(large_saves_rom, frames: 60)
    assert_empty survey.slow_scenes
    assert_equal 0, Profiler.work_in(survey.scenes.fetch(:play)).fetch(LOOKING_OVER, 0)
    assert_equal 0, survey.work.fetch(LOOKING_OVER, 0), "what goes in the quick memory is not weighed by it either"
  end

  def test_a_run_from_power_on_starts_past_it_too
    reading = Profiler.run(large_saves_rom, frames: 60, picture: false)
    assert_equal 0, Profiler.work_in(reading).fetch(LOOKING_OVER, 0)
  end

  def test_a_run_that_asks_for_power_on_still_sees_it
    reading = Profiler.run(large_saves_rom, frames: 60, settle: 0, picture: false)
    assert_operator Profiler.work_in(reading).fetch(LOOKING_OVER, 0), :>, 0
  end

  def test_settling_a_scene_moves_the_frames_measured
    assert_predicate Profiler.run(slow_at_first_rom, scene: :play, frames: 20, picture: false), :dropping_frames?
    refute_predicate Profiler.run(slow_at_first_rom, scene: :play, frames: 20, settle: 300, picture: false), :dropping_frames?
  end
end
