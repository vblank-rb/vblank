# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "open3"

# A TAPE WRITTEN OUT FOR ANOTHER EMULATOR. Which buttons are down on which frame has to survive the
# writing out exactly, since one frame of difference ruins a run.
class TestTapeExport < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  # mGBA's scripting as far as the script uses it: frames played one after another, each with the
  # keys the script had set when it began.
  FAKE_MGBA = <<~LUA
    local hooks, keys, shots = {}, 0, {}
    emu = {
      setKeys = function(_, mask) keys = mask end,
      reset = function() hooks.reset() end,
      screenshot = function(_, path) print("shot " .. path) end,
    }
    callbacks = { add = function(_, name, fn) hooks[name] = fn end }
    console = { log = function() end }
    dofile(arg[1])
    for _ = 1, tonumber(arg[2]) do
      print(keys)
      hooks.frame()
    end
  LUA

  private def cartridge(console: :gba)
    VBlank.build("EXPORT", console: console, out: StringIO.new, err: StringIO.new) do
      pass = var :pass, 0
      seen = var :seen, 0
      spent = var :spent, 0
      read = list :read, capacity: 30
      game_loop do
        pass += 1
        seen = 0
        seen = 1 if held(:right)
        read.push(seen) if read.length < 30
        repeat(3000) { spent += 1 } if (pass & 3) == 0
      end
    end
  end

  private def walk
    VBlank::Playthroughs::Playthrough.new("walk") do
      wait frames: 3
      hold :right, :a, frames: 4
      moment :walked
      press :start
    end
  end

  private def tape = walk.play(cartridge).tape

  private def file_in_movie(path, name)
    out, status = Open3.capture2("unzip", "-p", path, name)
    skip_on_this_machine "unzip is not installed" unless status.success?
    out
  end

  def test_the_mgba_script_holds_each_frames_buttons
    skip_on_this_machine "lua is not installed" unless system("which lua", out: File::NULL)
    Dir.mktmpdir do |dir|
      script = tape.write_mgba_script(cartridge, File.join(dir, "walk.lua"), pictures_in: "shots")
      fake = File.join(dir, "fake.lua")
      File.write(fake, FAKE_MGBA)
      out, status = Open3.capture2("lua", fake, script, "11")
      right_a = VBlank::Playthroughs::Playthrough.key_mask(%i[right a])
      start = VBlank::Playthroughs::Playthrough.key_mask(%i[start])

      assert status.success?, out
      assert_equal [0, 0, 0, right_a, right_a, right_a, right_a, "shot shots/walked.png", start, 0, 0, 0].map(&:to_s), out.lines(chomp: true)
    end
  end

  def test_the_movie_has_a_line_for_each_frame
    Dir.mktmpdir do |dir|
      path = tape.write_bizhawk_movie(cartridge, File.join(dir, "walk.bk2"))
      lines = file_in_movie(path, "Input Log.txt").lines(chomp: true)

      assert_equal "[Input]", lines.first
      assert_equal "[/Input]", lines.last
      assert_equal ["|...........|"] * 3 + ["|...R...A...|"] * 4 + ["|....S......|", "|...........|"], lines[2...-1]
    end
  end

  def test_the_movie_names_the_cartridge_and_its_moments
    Dir.mktmpdir do |dir|
      game = cartridge
      path = tape.write_bizhawk_movie(game, File.join(dir, "walk.bk2"))

      assert_includes file_in_movie(path, "Header.txt"), "SHA1 #{Digest::SHA1.hexdigest(game.buffer).upcase}\n"
      assert_includes file_in_movie(path, "Header.txt"), "Platform GBA\n"
      assert_match(/\Asubtitle 7 8 8 \d+ \h{8} walked\n\z/, file_in_movie(path, "Subtitles.txt"))
    end
  end

  # The strict list of frames a tape of passes comes to on one cartridge plays it there the same.
  def test_a_tape_of_passes_comes_to_frames_for_one_cartridge
    game = cartridge
    passes = walk.play(game, in_passes: true, on: "interpreter").tape
    frames = passes.in_frames_on(game)

    assert_nil frames.in_passes
    assert_operator frames.frames, :>, passes.frames
    assert_equal passes.play(game).game.list(:read), frames.play(game).game.list(:read)
    assert_equal frames.moments.keys, passes.moments.keys
  end

  def test_a_tape_of_passes_is_written_out_in_frames
    Dir.mktmpdir do |dir|
      game = cartridge
      passes = walk.play(game, in_passes: true, on: "interpreter").tape
      path = passes.write_bizhawk_movie(game, File.join(dir, "walk.bk2"))

      assert_equal passes.in_frames_on(game).frames, file_in_movie(path, "Input Log.txt").lines.grep(/\A\|/).length
    end
  end

  def test_another_console_is_refused
    Dir.mktmpdir do |dir|
      error = assert_raises(ArgumentError) { tape.write_mgba_script(cartridge(console: :gbc), File.join(dir, "walk.lua")) }

      assert_match(/Game Boy Advance/, error.message)
    end
  end

  def test_a_tape_from_a_save_is_refused
    from_a_save = tape.with(starts_from: "a save 0x12345678")
    error = assert_raises(ArgumentError) { from_a_save.write_bizhawk_movie(cartridge, "unused.bk2") }

    assert_match(/from power-on/, error.message)
  end
end
