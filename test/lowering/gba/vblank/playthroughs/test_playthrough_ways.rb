# frozen_string_literal: true

require "test_helper"
require "stringio"

# A STEERED PLAYTHROUGH ON EVERY WAY OF RUNNING A GAME. The same script, reading the game through the
# same words, plays on the emulator, the interpreter, and the game built as C, as JavaScript and as
# Ruby, and in a window that shows each frame at the console's rate.
class TestPlaythroughWays < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  # A number that climbs while :right is down, its first values kept in a list.
  private def cartridge
    VBlank.build("WAYS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      sprite :dot, at: [8, 8]
      x = var :x, 0
      trail = list :trail, capacity: 8
      guards = pool :guards, step: 0, capacity: 2
      guards.spawn step: 5
      game_loop do
        x += 1 if held(:right)
        trail.push(x) if trail.length < 8
        guards.each { |guard| guard.step = guard.step + 1 }
      end
    end
  end

  private def steered
    VBlank::Playthroughs::Playthrough.new("walk") do
      steer "walk to ten", within: 200 do |game|
        next :done if game.var(:x) >= 10

        game.var(:x) < 10 ? [:right] : []
      end
      moment :there
    end
  end

  VBlank::Playthroughs::LoweredGame.ways.each do |way|
    define_method(:"test_a_steered_script_finishes_on_#{way}") do
      played = steered.play(cartridge, on: way)

      assert_equal 10, played.game.var(:x), "the steering read the game and stopped where it said"
      assert_operator played.game.list(:trail).length, :>, 0, "a list reads the same way"
      assert_operator played.game.pool(:guards, :step).compact.first, :>, 5, "and so does a pool"
      assert_includes played.moments.keys, :there
    end
  end

  # What a window is asked, standing in for one.
  class Screen
    attr_reader :shown, :waits, :repeats

    def initialize(stop_after: nil, held: [], speed: 1, paused_on: nil)
      @repeats = []
      @stop_after = stop_after
      @held = held
      @speed = speed
      @paused_on = paused_on
      @shown = []
      @waits = []
      @clock = 0.0
    end

    def show(pixels, width, height) = @shown << [pixels.length, width, height]
    def play_sound(_left, _rate, _right) = nil
    def sound_waiting = nil
    def repeating_picture=(said)
      @repeats << said
    end

    def held_buttons(_frame) = @held
    def fast_forward_speed(_pass) = @speed

    # Paused once, for a long while by the clock, at the frame it was told.
    def hold_while_paused
      return false unless @shown.length == @paused_on

      @paused_on = nil
      @clock += 5.0
      true
    end

    def stop? = @stop_after && @shown.length >= @stop_after
    def now = @clock

    def wait_until(seconds)
      @waits << seconds
      @clock = [@clock, seconds].max
    end
  end

  def test_a_window_shows_every_frame_at_the_consoles_rate
    window = Screen.new
    played = steered.play(cartridge, on: "interpreter", window: window)

    assert_equal played.frames, window.shown.length
    assert_equal [38_400, 240, 160], window.shown.first
    assert_in_delta VBlank::Console::ADVANCE.frame_seconds, window.waits[1] - window.waits[0], 1e-9
  end

  def test_closing_the_window_ends_the_playing
    assert_raises(VBlank::Playthroughs::WindowStepper::WindowClosed) do
      steered.play(cartridge, on: "interpreter", window: Screen.new(stop_after: 3))
    end
  end

  # The same run with nobody watching, for the watched ones to match.
  private def untouched = steered.play(cartridge, on: "interpreter")

  def test_buttons_held_in_the_window_do_not_reach_the_game
    watched = steered.play(cartridge, on: "interpreter", window: Screen.new(held: %i[left right a]))

    assert_equal untouched.moments, watched.moments
    assert_equal untouched.frames, watched.frames
  end

  def test_fast_forward_shows_fewer_frames_and_plays_the_same_run
    window = Screen.new(speed: 4)
    watched = steered.play(cartridge, on: "interpreter", window: window)

    assert_equal untouched.moments, watched.moments
    assert_operator window.shown.length, :<, watched.frames
  end

  def test_pausing_plays_the_same_run
    watched = steered.play(cartridge, on: "interpreter", window: Screen.new(paused_on: 4))

    assert_equal untouched.moments, watched.moments
  end

  def test_a_watched_playing_sends_the_speaker_a_frame_of_silence_where_it_has_no_sound
    sound = []
    window = Screen.new
    window.define_singleton_method(:play_sound) { |left, rate, right| sound << [left.length, rate, right.length] }
    steered.play(cartridge, on: "interpreter", window: window)

    rate = VBlank::Diagnostics::SoundRecording::CARTRIDGE_RATES.fetch(:gba)
    frame = (rate * VBlank::Console::ADVANCE.frame_seconds).round
    assert_equal [frame, rate, frame], sound.first
  end

  # A note that sounds from the first frame, and a script that plays long enough to hear it.
  private def tuneful_cartridge
    VBlank.build("TUNE", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      sprite :dot, at: [8, 8]
      enable_sound
      song(:tune) do
        voice(:lead) { note :C5, :whole }
      end
      play_song :tune
      game_loop { nil }
    end
  end

  private def a_few_frames
    VBlank::Playthroughs::Playthrough.new("listen") { wait frames: 40 }
  end

  %w[native web ruby].each do |way|
    define_method(:"test_a_window_hears_the_game_on_#{way}") do
      heard = []
      window = Screen.new
      window.define_singleton_method(:play_sound) { |left, rate, right| heard << [left, rate, right] }
      a_few_frames.play(tuneful_cartridge, on: way, window: window)

      rate = VBlank::IR::Backends::Native::HeadlessRun::SOUND_RATE
      frame = (rate * VBlank::Console::ADVANCE.frame_seconds).round
      assert_equal [rate], heard.map { |_, said, _| said }.uniq
      assert_in_delta frame, heard.last.first.length, 2, "a frame's sound, for each speaker"
      assert heard.last(10).any? { |left, _, _| left.any? { |sample| !sample.zero? } }, "the note reached the speaker"
    end
  end

  # A game whose every pass takes the console several frames.
  private def slow_cartridge
    VBlank.build("SLOW", console: :gba, validate: false, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop do
        repeat(20) { clear_screen :blue }
      end
    end
  end

  def test_a_frame_with_no_new_pass_is_told_to_the_window_as_a_repeat
    frames = 0
    wait = VBlank::Playthroughs::Playthrough.new("wait") do
      steer "a while", within: 200 do
        frames += 1
        frames > 120 ? :done : []
      end
    end
    window = Screen.new
    wait.play(slow_cartridge, on: "emulator", window: window)

    repeated = window.repeats.count(true)
    assert_operator repeated, :>, window.repeats.length / 3, "a game of two frames a pass repeats about every other one"
    assert_operator repeated, :<, window.repeats.length, "and some frames are new"
  end

  def test_a_way_that_plays_a_pass_a_frame_never_repeats_a_picture
    window = Screen.new
    steered.play(cartridge, on: "interpreter", window: window)

    refute_includes window.repeats, true
  end

  def test_a_way_there_is_not_is_refused_naming_them
    error = assert_raises(ArgumentError) { steered.play(cartridge, on: "abacus") }

    assert_match(/interpreter, native, web, ruby/, error.message)
  end
end
