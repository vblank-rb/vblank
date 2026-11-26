# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The Flash player, run with no window: a small movie that traces a line each frame and one for each key
# is played a known number of frames, and every line it traced is read back in order.
class TestFlashPlayer < Minitest::Test
  FlashPlayer = VBlank::Diagnostics::FlashPlayer
  Haxe = VBlank::IR::Backends::Flash::Haxe
  SOURCE = File.expand_path("../../fixtures/frame_counter", __dir__)

  def setup
    @folder = Dir.mktmpdir("vblank-flash-test")
    @swf = Haxe.compile(SOURCE, main: "Main", swf: File.join(@folder, "frame_counter.swf"), width: 320, height: 240)
  end

  def teardown
    FileUtils.remove_entry(@folder)
  end

  def test_traces_a_line_for_each_frame_in_order
    assert_equal ["frame 1", "frame 2", "frame 3"], FlashPlayer.play(@swf, frames: 3)
  end

  def test_a_key_pressed_on_a_frame_is_traced_before_that_frame
    lines = FlashPlayer.play(@swf, frames: 4, keys: [[2, :left, :down], [4, :left, :up], [4, :space, :down]])

    assert_equal ["frame 1", "key down 37", "frame 2", "frame 3", "key up 37", "key down 32", "frame 4"], lines
  end

  def test_a_tape_that_asks_for_no_such_key_is_refused
    error = assert_raises(FlashPlayer::Error) { FlashPlayer.play(@swf, frames: 1, keys: [[1, :wibble, :down]]) }

    assert_includes error.message, "no key is called"
  end

  def test_a_missing_player_says_how_to_build_it
    error = assert_raises(FlashPlayer::Error) { FlashPlayer.play(@swf, frames: 1, harness: File.join(@folder, "nothing")) }

    assert_includes error.message, "rake compile_flash_player"
  end

  def test_a_missing_movie_is_refused
    assert_raises(FlashPlayer::Error) { FlashPlayer.play(File.join(@folder, "none.swf"), frames: 1) }
  end
end
