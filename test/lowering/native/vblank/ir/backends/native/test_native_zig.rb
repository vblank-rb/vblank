# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# How a program zig built is run and read back (Computer::ProgramRun.run).
class TestNativeZig < Minitest::Test
  include NativeComparison

  Zig = VBlank::IR::Backends::Native::Zig

  # Ruby threads that do nothing but count, for as long as the block runs: what the tests beside
  # this one are doing whenever they replay a game on the interpreter.
  private def beside_busy_threads(count)
    stop = false
    busy = Array.new(count) { Thread.new { nil until stop } }
    yield
  ensure
    stop = true
    busy.each(&:join)
  end

  # A program for another computer is asked for by name, and a name there is no build for is
  # refused before anything is built, saying which there are.
  def test_a_computer_there_is_no_build_for_is_refused
    game = VBlank.game("NOWHERE", consoles: %i[gba]) do
      screen :bitmap
      game_loop { clear_screen :red }
    end
    error = assert_raises(VBlank::IR::Backends::Computer::LoweringError) do
      Native.new.build_desktop(game, File.join(Dir.tmpdir, "nowhere"), target: :amiga, err: nil)
    end

    assert_match(/amiga/, error.message)
    assert_match(/windows, linux, linux_arm/, error.message)
  end

  # A game's C is kept in a folder named for what it holds and used again by the next build of the
  # same game, and folders nothing has used for hours are cleared away now and then. A folder made
  # hours ago and used again now is in use: clearing it took game.c from under the compiler, which
  # failed a test in one run in a few and passed when played again.
  def test_a_source_folder_used_again_is_not_cleared_from_under_the_compile
    name = :"kept_#{Process.pid}_#{rand(1 << 30)}"
    program = program_of do
      screen :bitmap
      n = var name, 0
      game_loop { n += 1 }
    end
    Native.new.build_headless(program, mode: :checked)
    kept = File.join(Dir.tmpdir, "vblank-native")
    folder = Dir.glob(File.join(kept, "src-*", "game.c")).find { |file| File.read(file).include?(name.to_s) }.then { |file| File.dirname(file) }
    long_ago = Time.now - Zig::KEEP_PROGRAM_SECONDS - 60
    File.utime(long_ago, long_ago, folder)
    FileUtils.rm_f(File.join(kept, ".pruned")) # so the next build clears what is old

    exe = Native.new.build_headless(program, mode: :fast)

    assert_path_exists File.join(folder, "game.c")
    assert_match(/^frame 1$/, Computer::ProgramRun.run(exe, args: [1], input: "0\n", seconds: 15))
  end

  # A PROGRAM'S RUN DOES NOT WAIT ON RUBY. Ruby runs one thread at a time, and a thread reading
  # what a program prints as it prints it takes its turn again for every piece, behind every
  # thread that is busy. A native run puts tests side by side, so a program that ends in a
  # second took minutes that way, with its output backed up behind a reader waiting its turn,
  # and was stopped as one that never ends.
  def test_a_program_that_prints_a_lot_ends_in_time_beside_busy_ruby_threads
    program = program_of do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :red
        n += 1
      end
    end
    exe = Native.new.build_headless(program, mode: :checked)
    frames = 60

    printed = beside_busy_threads(3) do
      Computer::ProgramRun.run(exe, args: [frames, "--every-picture"], input: "0\n" * frames, seconds: 15)
    end

    assert_equal frames, printed.scan(/^frame \d+$/).length, "every frame should have been printed"
    assert_operator printed.bytesize, :>, 5_000_000, "and the run should have been one that prints a great deal"
  end
end
