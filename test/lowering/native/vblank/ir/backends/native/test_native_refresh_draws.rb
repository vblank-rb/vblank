# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A PICTURE SHOWN FOR SEVERAL REFRESHES IS DRAWN AS FEW TIMES AS THE DISPLAY ALLOWS. On a monitor of
# a hundred and twenty a second each of the console's pictures is up for two refreshes. SDL's vsync
# takes a number of refreshes to wait for, so the window asks for the picture's own and draws it once;
# a display that refuses that number is asked for one refresh, and the picture is drawn once for each
# of its refreshes, which is what the window always did. Either way the pictures are drawn for
# exactly the refreshes they are shown for (rg_handover_for says which in
# test_native_pacing.rb), and --frame-times says what was done.
#
# The stand-in display of the tests takes a wait for one refresh and refuses more, so it plays the
# second way; which way a real display goes is for the person running it to see.
class TestNativeRefreshDraws < Minitest::Test
  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze

  GAME = VBlank.game("REFRESHDRAW", consoles: %i[gba]) do
    screen :bitmap
    clear_screen :blue
    game_loop {}
  end

  # What --frame-times says about drawing for a monitor of +rate+ refreshes a second: the picture's
  # refreshes, how many times it is drawn, and how many refreshes the display waits each time.
  private def drawing_for(rate)
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(GAME, File.join(dir, "game"), err: nil)
      _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "10", "--frame-times",
                                              "--settings-file", File.join(dir, "none.txt"), "--refresh-rate", rate.to_s,
                                              stdin_data: "0\n" * 10)
      assert_predicate status, :success?, said
      refreshes = said[/^pacing: the monitor, (\d+) refreshes a picture/, 1]
      drawn, waited = said.match(/^drawing: each picture is drawn (\d+) times?, the display waiting for (\d+) refreshe?s? each time$/)&.captures
      [refreshes&.to_i, drawn&.to_i, waited&.to_i]
    end
  end

  def test_a_picture_is_drawn_for_exactly_the_refreshes_it_is_shown_for
    [60, 120, 180].each do |rate|
      refreshes, drawn, waited = drawing_for(rate)

      refute_nil drawn, "a #{rate}Hz monitor paces the game, so the window says how it draws"
      assert_equal rate / 60, refreshes
      assert_equal refreshes, drawn * waited, "a #{rate}Hz monitor: #{drawn} drawing(s) each waiting for #{waited}"
    end
  end

  # A monitor that is not a whole number of the console's rate does not pace the game, so nothing
  # is handed over to it to wait for.
  def test_a_monitor_that_does_not_pace_the_game_leaves_it_to_the_consoles_clock
    refreshes, drawn, = drawing_for(144)

    assert_nil refreshes, "a 144Hz monitor leaves the pacing to the console's clock"
    assert_nil drawn
  end
end
