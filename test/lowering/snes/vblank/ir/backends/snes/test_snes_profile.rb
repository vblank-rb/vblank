# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# A Super Nintendo cartridge measured as it runs (Diagnostics::SNESProfiler): how many frames each
# pass of the game loop took, read from the running cartridge.
class TestSNESProfile < Minitest::Test
  LIGHT = VBlank.game("LIGHT", consoles: %i[snes]) do
    total = 0
    game_loop { total += 1 }
  end

  # Every fourth pass does far more work than a frame holds.
  HEAVY_NOW_AND_THEN = VBlank.game("HEAVY", consoles: %i[snes]) do
    total = 0
    pass = 0
    game_loop do
      pass += 1
      repeat(9000) { total += 3 } if (pass & 3) == 0
    end
  end

  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  def test_a_light_game_takes_a_frame_a_pass
    result = rom_of(LIGHT).profile(out: StringIO.new, frames: 20)

    assert_equal 20, result.passes
    assert_equal 20, result.frames
    assert_equal 1, result.slowest_frames
    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_in_delta 60.1, result.fps, 0.5
  end

  def test_a_pass_that_runs_over_is_counted_and_found
    result = rom_of(HEAVY_NOW_AND_THEN).profile(out: StringIO.new, frames: 20)

    assert_operator result.slowest_frames, :>, 1
    assert_equal 0, result.slowest_pass % 4, "a heavy pass"
    assert_operator result.frames, :>, result.passes
    assert_operator result.fps, :<, 59
  end

  def test_the_report_says_the_frame_rate_and_the_slowest_pass
    out = StringIO.new
    rom_of(HEAVY_NOW_AND_THEN).profile(out: out, frames: 20)

    assert_match(/20 passes of the game loop in \d+ frames/, out.string)
    assert_match(/slowest pass took \d+ frames/, out.string)
  end

  def test_the_report_comes_as_data_too
    out = StringIO.new
    rom_of(LIGHT).profile(format: :json, out: out, frames: 5)

    assert_equal 5, JSON.parse(out.string).fetch("passes")
  end

  def test_a_scene_to_measure_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom_of(LIGHT).profile(out: StringIO.new, scene: :title) }

    assert_match(/cannot be told a scene/, error.message)
  end
end
