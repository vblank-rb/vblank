# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "zlib"

# `vblank build --format=flash` writes a movie that shows the game's picture and answers its keys. The movie
# is played in the Flash player's harness, which has no window, so it is built to trace the picture's check
# number each time it paints (Flash#build_swf's trace_pictures), and that number is held to the
# interpreter's picture for the same game.
class TestFlashPage < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  GAME = VBlank.game "mover", consoles: %i[gba] do
    x = var :x, 20
    game_loop do
      clear_screen :black
      fill_rect x, 40, 8, 8, :green
      x.increase!(2) if held(:right)
      x.decrease!(2) if held(:left)
    end
  end

  def setup
    @folder = Dir.mktmpdir("vblank-flash-page")
    @swf = Flash.new.build_swf(GAME, File.join(@folder, "mover.swf"), console: :gba, trace_pictures: true, err: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@folder)
  end

  def test_the_movie_is_written_where_it_was_asked_to_be
    assert_path_exists @swf
    assert_includes %w[FWS CWS], File.binread(@swf, 3)
  end

  def test_it_shows_the_picture_the_game_draws
    painted = FlashPlayerHelper.painted(@swf, frames: 6)

    refute_empty painted
    assert_equal interpreter_pictures([]).first(painted.size), painted
  end

  def test_it_answers_its_keys
    painted = FlashPlayerHelper.painted(@swf, frames: 40, keys: [[10, :right, :down]])
    moving = interpreter_pictures([:right]) # the same game with the right key held from the first frame

    assert_operator painted.uniq.size, :>, 1, "the picture changed once the key went down"
    assert_includes moving, painted.last
  end

  # A game that saves keeps its save memory in a SharedObject, written when it has changed and been quiet a moment.
  def test_a_game_that_saves_keeps_its_save_memory
    saver = VBlank.game "saver", consoles: %i[gba] do
      best = save_var :best, 0
      best.store!(7)
      game_loop do
        clear_screen :black
      end
    end
    swf = Flash.new.build_swf(saver, File.join(@folder, "saver.swf"), console: :gba, trace_pictures: true, err: StringIO.new)
    saved = VBlank::Diagnostics::FlashPlayer.play(swf, frames: 12, real_time: true).grep(/\Asaved /)

    refute_empty saved
    assert_match(/07000000/, saved.last, "the number 7, low byte first, is in what was kept")
  end

# The movie plays by the clock, so it goes on: a count of the milliseconds times the console clock that passed 32 bits
# stopped it after a tenth of a second.
def test_it_keeps_playing_past_the_first_tenth_of_a_second
  painted = FlashPlayerHelper.painted(@swf, frames: 16)

  assert_operator painted.size, :>, 12
end

  def test_the_movie_is_for_the_size_of_the_screen_enlarged
    movie = File.binread(@swf)
    body = movie.start_with?("CWS") ? Zlib::Inflate.inflate(movie[8..]) : movie[8..]
    bits = body.unpack1("B*")
    size = bits[0, 5].to_i(2)
    _min_x, max_x, _min_y, max_y = (0..3).map { |at| bits[5 + (at * size), size].to_i(2) }

    assert_equal [240 * 3 * 20, 160 * 3 * 20], [max_x, max_y]
  end

  private

  # The check number of the interpreter's picture after each of 40 frames with +buttons+ held.
  def interpreter_pictures(buttons)
    pictures = []
    interpreter = VBlank::IR::Backends::Reference.new.hold(*buttons)
    interpreter.each_vblank { pictures << format("%08x", Zlib.crc32(interpreter.screen.shown.pack("v*"))) }
    interpreter.run(GAME.checked_program(console: :gba), frames: 40)
    pictures
  end

  module FlashPlayerHelper
    module_function

    # The check number of the picture each time the movie painted it. The movie plays by the machine's clock, so
    # it is played in real time and a busy machine can make a run differ; the harness's own clock will fix that.
    def painted(swf, frames:, keys: [])
      VBlank::Diagnostics::FlashPlayer.play(swf, frames: frames, keys: keys, real_time: true).grep(/\Apicture-crc /).map { |line| line.delete_prefix("picture-crc ") }
    end
  end
end
