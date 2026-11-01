# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A PICTURE THAT IS THE ONE ALREADY UP IS NOT SHOWN AGAIN. A game sitting on a title screen finishes
# the same picture sixty times a second, and uploading and drawing it every time costs the computer
# and its graphics card for nothing. The window compares what the game finished with what it last
# put up, and shows the same picture again by doing nothing: the report of --frame-times says how
# many it did that for, and how evenly the pictures were still handed over, since the game must run
# at the same speed on a screen that stands still, and make its sound at the same pace.
#
# Played in SDL's stand-in display, told to pace as for a monitor that refreshes a number of times
# a second (--refresh-rate), with the frame rate the window shows in its corner turned off in
# the settings file: its words change as the rate is measured, which is a reason to draw.
class TestNativeStillPicture < Minitest::Test
  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  FRAMES = 90

  Played = Struct.new(:said, :seconds, keyword_init: true) do
    def not_drawn = said[/^pictures shown that were the one already up, so not drawn again: (\d+)$/, 1].to_i
    def pictures = said[/^pictures: (\d+),/, 1].to_i
    def middle_ms = said[/^pictures: \d+, [\d.]+ to [\d.]+ ms apart, ([\d.]+) in the middle$/, 1].to_f
  end

  # A picture drawn once and then nothing, and a box that moves along every frame.
  STILL = VBlank.game("STILLPIC", consoles: %i[gba]) do
    screen :bitmap
    clear_screen :blue
    fill_rect 20, 20, 60, 30, :red
    game_loop {}
  end

  MOVING = VBlank.game("MOVINGPIC", consoles: %i[gba]) do
    screen :bitmap
    x = 0
    game_loop do
      clear_screen :blue
      draw_rect_at x, 20, 30, 30, :red
      x += 1
    end
  end

  private def play(game, lines: [], refresh_rate: 60)
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game, File.join(dir, "game"), err: nil)
      settings = File.join(dir, "settings.txt")
      File.write(settings, "frame_rate = off\n")
      script = (lines + ["0"] * FRAMES).first(FRAMES).map { |line| "#{line}\n" }.join
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", FRAMES.to_s, "--settings-file", settings,
                                              "--frame-times", "--refresh-rate", refresh_rate.to_s, stdin_data: script)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_predicate status, :success?, said
      Played.new(said: said, seconds: took)
    end
  end

  def test_a_picture_standing_still_is_drawn_once_and_every_picture_is_still_counted
    played = play(STILL)

    assert_operator played.not_drawn, :>=, FRAMES - 3, played.said
    assert_equal FRAMES, played.pictures, "--frame-times counts every picture shown, drawn or not: #{played.said}"
  end

  def test_a_picture_that_moves_is_drawn_every_time
    assert_equal 0, play(MOVING).not_drawn
  end

  # The monitor paces the game, so a picture not drawn must still last a monitor's frame: the game
  # runs at the monitor's speed whether or not anything is drawn, on a sixty-a-second monitor and on
  # one of a hundred and twenty, where a picture is two refreshes. A still game that was held only
  # to the fastest it may go (two parts in a hundred over the monitor) would run faster than that.
  def test_a_still_picture_lasts_as_long_as_the_monitor_makes_it_on_a_sixty_and_a_hundred_and_twenty_a_second_monitor
    [60, 120].each do |rate|
      still = play(STILL, refresh_rate: rate)

      assert_in_delta 1000.0 / 60, still.middle_ms, 0.25, "a still picture on a #{rate}Hz monitor: #{still.said}"
      assert_operator still.seconds, :>=, FRAMES / 60.0 * 0.995, "#{FRAMES} frames cannot go by faster than the monitor shows them"
    end
  end

  # The variables window is drawn over the picture, so while it is up the window is drawn every
  # frame whether or not the game's picture changes.
  def test_a_window_over_the_picture_keeps_the_window_drawn
    played = play(STILL, lines: ["0", "0", "0 panel:variables"])

    assert_operator played.not_drawn, :<=, 4, played.said
  end

  # Taking a window away is a change to what is on screen, though the game's picture is the same:
  # the first picture after it is drawn too, or the window stays up over a still game.
  def test_a_window_taken_away_is_drawn_away
    open_for_three = ["0", "0", "0 panel:variables", "0", "0", "0 panel:variables"]
    with_a_window = play(STILL, lines: open_for_three).not_drawn

    assert_equal play(STILL).not_drawn - 4, with_a_window
  end
end
