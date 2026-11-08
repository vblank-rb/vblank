# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# A PLAYING COUNTED IN PASSES OF THE GAME LOOP. The game below takes one frame over some passes and
# several over others on a console, and one on the ways that play a pass a frame. Counted in frames,
# the same presses land on different passes on each; counted in passes, the game reads the same
# buttons on the same pass on every way.
class TestPlaythroughPasses < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  HEAVY = 3000
  KEPT = 40

  private def game_for(console, frame_clock: false)
    VBlank.build("PASSES", console: console, out: StringIO.new, err: StringIO.new) do
      pass = var :pass, 0
      seen = var :seen, 0
      spent = var :spent, 0
      read = list :read, capacity: KEPT
      steps = var :steps, 0
      game_loop do
        pass += 1
        seen = 0
        seen = 1 if held(:right)
        seen += 2 if pressed(:a)
        read.push(seen) if read.length < KEPT
        steps += 1 if (pass & 1) == 1
        spent += frames_since_power_on if frame_clock
        repeat(HEAVY) { spent += 1 } if (pass & 3) == 0
      end
    end
  end

  private def cartridge = game_for(:gba)

  # Down, up and a tap, at places a heavy pass sits between.
  private def script
    VBlank::Playthroughs::Playthrough.new("presses") do
      wait frames: 2
      hold :right, frames: 3
      press :a
      wait frames: 3
      hold :right, frames: 7
      press :a
      moment :pressed_last
      wait frames: 6
    end
  end

  private def recorded = script.play(cartridge, in_passes: true, on: "interpreter").tape

  private def wanted = recorded.play(cartridge, on: "interpreter").game.list(:read)

  VBlank::Playthroughs::LoweredGame.ways.each do |way|
    define_method(:"test_a_tape_of_passes_reads_the_same_buttons_on_#{way}") do
      assert_equal wanted, recorded.play(cartridge, on: way).game.list(:read).first(wanted.length)
    end
  end

  def test_it_is_what_the_script_says_pass_by_pass
    assert_equal [0, 0, 1, 1, 1, 2, 0, 0, 0, 0], wanted.first(10)
  end

  def test_the_same_tape_counted_in_frames_lands_elsewhere_on_a_slow_cartridge
    frames = script.play(cartridge, on: "interpreter").tape

    refute_equal wanted, frames.play(cartridge).game.list(:read).first(wanted.length)
  end

  def test_a_recording_on_the_cartridge_plays_on_the_rules_only_run_and_back
    on_the_cartridge = script.play(cartridge, in_passes: true).tape

    assert_equal wanted, on_the_cartridge.play(cartridge, on: "logic").game.list(:read).first(wanted.length)
  end

  def test_a_cartridge_takes_more_frames_than_passes
    assert_operator recorded.in_frames_on(cartridge).frames, :>, recorded.frames
  end

  def test_moments_name_passes
    assert_equal({ pressed_last: 19 }, recorded.moments)
  end

  def test_a_color_cartridge_reads_the_same_buttons
    assert_equal wanted, recorded.play(game_for(:gbc)).game.list(:read).first(wanted.length)
  end

  def test_a_super_nintendo_cartridge_reads_the_same_buttons
    assert_equal wanted, recorded.play(game_for(:snes)).game.list(:read).first(wanted.length)
  end

  def test_a_variable_of_the_game_can_be_what_counts
    played = script.play(cartridge, in_passes: :steps, on: "interpreter")
    tape = played.tape

    assert_equal played.game.list(:read), tape.play(cartridge, on: "interpreter").game.list(:read)
    assert_equal played.game.var(:steps), tape.play(cartridge).game.var(:steps)
    assert_equal played.frames, played.game.var(:steps)
    assert_equal played.game.list(:read).first(20), tape.play(cartridge).game.list(:read).first(20)
  end

  def test_the_tape_says_what_it_counts_and_reads_back
    Dir.mktmpdir do |dir|
      path = recorded.write(File.join(dir, "walk.tape"))

      assert_includes File.read(path).lines.first(4), "counts: passes\n"
      assert_equal recorded, VBlank::Playthroughs::Tape.read(path)
      assert_equal wanted, VBlank::Playthroughs::Tape.read(path).play(cartridge, on: "native").game.list(:read).first(wanted.length)
    end
  end

  def test_a_tape_of_frames_says_nothing_new
    refute_includes script.play(cartridge, on: "interpreter").tape.to_s, "counts:"
  end

  def test_a_tape_can_count_a_variable
    tape = script.play(cartridge, in_passes: :steps, on: "interpreter").tape

    assert_includes tape.to_s, "counts: variable steps\n"
    assert_equal tape, VBlank::Playthroughs::Tape.parse(tape.to_s)
  end

  def test_a_game_that_reads_the_frame_clock_is_refused
    error = assert_raises(ArgumentError) { script.play(game_for(:gba, frame_clock: true), in_passes: true) }

    assert_match(/counts frames/, error.message)
    assert_match(/variable/, error.message)
  end

  def test_a_cartridge_file_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gba")
      File.binwrite(path, cartridge.buffer)
      error = assert_raises(ArgumentError) { script.play(path, in_passes: true) }

      assert_match(/cartridge file/, error.message)
    end
  end

  def test_a_counter_that_never_moves_stops_the_playing
    game = VBlank.build("STILL", console: :gba, out: StringIO.new, err: StringIO.new) do
      still = var :still, 0
      total = var :total, 0
      game_loop { total += 1 if still == 1 }
    end
    error = assert_raises(VBlank::Playthroughs::PassesStopped) { script.play(game, in_passes: :still, on: "interpreter") }

    assert_match(/still/, error.message)
  end

  def test_a_variable_the_game_does_not_have_is_refused
    error = assert_raises(ArgumentError) { script.play(cartridge, in_passes: :nothing, on: "interpreter") }

    assert_match(/nothing/, error.message)
  end

  def test_something_else_is_refused
    error = assert_raises(ArgumentError) { script.play(cartridge, in_passes: 3, on: "interpreter") }

    assert_match(/in_passes/, error.message)
  end

  def test_a_comparison_of_a_tape_of_passes_is_refused
    error = assert_raises(ArgumentError) { recorded.compare(cartridge, cartridge) }

    assert_match(/passes/, error.message)
  end
end
