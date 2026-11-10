# frozen_string_literal: true

require "test_helper"

# WHAT A PAUSED GAME'S WINDOW DOES WHILE IT WAITS (runtime/rg_pause.h). Nothing in a paused game
# moves, so the window sleeps until it has an event instead of drawing sixty times a second: a few
# frames are drawn after each event, since Dear ImGui settles a hover or a click over several, and
# one a frame while the menu or a window over the picture is open. The sleep has a timeout, so a file
# still owed is written, and a pause with nothing owed sleeps for a tenth of a second at a time.
class TestNativePause < Minitest::Test
  Zig = VBlank::IR::Backends::Native::Zig
  Computer = VBlank::IR::Backends::Computer
  HARNESS = Ractor.make_shareable(File.expand_path("pause_harness.c", __dir__))

  FRAME_NS = 16_742_706 # a frame of the console's own clock: 280,896 of its 2^24 ticks a second

  def test_an_event_owes_four_drawings_and_no_event_owes_what_was_owed_before
    assert_equal [4, 4, 0, 2], asked("owed 0 1", "owed 9 1", "owed 0 0", "owed 2 0").flatten.map(&:to_i)
  end

  def test_a_pause_with_nothing_to_draw_or_write_sleeps_a_tenth_of_a_second
    assert_equal [100], asked("wait 0 0 0 #{FRAME_NS}").flatten.map(&:to_i)
  end

  # Drawings owed, a window open over the picture or a file owed each keep the sleep to the rest of
  # the frame, rounded up to a whole millisecond: 16.7 is 17.
  def test_a_pause_that_draws_or_owes_a_file_sleeps_to_the_end_of_the_frame
    answers = asked("wait 2 0 0 #{FRAME_NS}", "wait 0 1 0 #{FRAME_NS}", "wait 0 0 1 #{FRAME_NS}", "wait 0 0 1 4000000", "wait 0 0 1 0")

    assert_equal [17, 17, 17, 4, 0], answers.flatten.map(&:to_i)
  end

  # The harness's answers to +questions+, a line each, split into words — at both of the settings
  # the backend is built at, which have to agree.
  private def asked(*questions)
    checked, fast = %i[checked fast].map do |mode|
      exe = Zig.compile_without_sdl([HARNESS], mode: mode)
      Computer::ProgramRun.run(exe, input: questions.map { |question| "#{question}\n" }.join).lines.map(&:split)
    end
    assert_equal checked, fast, "the checked and the optimised build should answer alike"
    checked
  end
end
