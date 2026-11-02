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
    attr_reader :shown, :waits

    def initialize(stop_after: nil)
      @stop_after = stop_after
      @shown = []
      @waits = []
      @clock = 0.0
    end

    def show(pixels, width, height) = @shown << [pixels.length, width, height]
    def play_sound(_left, _rate, _right) = nil
    def held_buttons(_frame) = []
    def hold_while_paused = false
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
    assert_raises(VBlank::Playthroughs::WatchedGame::WindowClosed) do
      steered.play(cartridge, on: "interpreter", window: Screen.new(stop_after: 3))
    end
  end

  def test_a_way_there_is_not_is_refused_naming_them
    error = assert_raises(ArgumentError) { steered.play(cartridge, on: "abacus") }

    assert_match(/interpreter, native, web, ruby/, error.message)
  end
end
