# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHAT A SCRIPT CAN ASK OF THE GAME IT STEERS, on every way of running it: how many passes of the game
# loop have finished (`game.passes`), and whether the game has a variable (`game.var?`). The game counts
# its own passes at the end of each, and every fourth pass is heavy enough to take the console more than
# a frame, so on the cartridge the passes fall behind the frames and still match the game's own count.
class TestPlaythroughScriptReads < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  HEAVY_PASS_ADDITIONS = 3000 # how many times a heavy pass adds one, which takes the Advance over a frame
  FRAMES_READ = 40

  private def cartridge
    VBlank.build("READS", console: :gba, out: StringIO.new, err: StringIO.new) do
      done = var :done, 0
      spent = var :spent, 0
      game_loop do
        repeat(HEAVY_PASS_ADDITIONS) { spent += 1 } if (done & 3) == 3
        done += 1
      end
    end
  end

  # What a block reads of the game, before every frame: the passes, the game's own count, and whether
  # it has a name it has and a name it lacks. Public: a script's block calls back through it.
  def reading_of(game) = [game.passes, game.var(:done), game.var?(:done), game.var?(:nothing)]

  # Reads before every frame, for FRAMES_READ frames.
  private def steering(seen)
    test = self
    VBlank::Playthroughs::Playthrough.new("read the passes") do
      steer "read for a while", within: FRAMES_READ + 1 do |game|
        seen << test.reading_of(game)
        seen.length > FRAMES_READ ? :done : []
      end
    end
  end

  private def assert_passes_are_the_games_own(seen)
    assert_equal(seen.map { |_, done, *| done }, seen.map(&:first), "the passes are the game's own count, frame by frame")
    assert_operator seen.last.first, :>, FRAMES_READ / 2, "and they went up"
    assert_equal [[true, false]], seen.map { |*, has, lacks| [has, lacks] }.uniq, "a name the game has, and one it lacks"
  end

  VBlank::Playthroughs::LoweredGame.ways.each do |way|
    define_method(:"test_a_steering_script_reads_the_passes_finished_on_#{way}") do
      seen = []
      played = steering(seen).play(cartridge, on: way)

      assert_passes_are_the_games_own(seen)
      assert_equal seen.last.first, played.game.passes, "the game handed back answers the same"
    end
  end

  def test_the_cartridge_takes_more_frames_than_passes
    seen = []
    steering(seen).play(cartridge)

    assert_operator seen.last.first, :<, seen.length - 1, "the heavy passes took more than a frame each"
  end

  def test_a_watching_script_reads_the_passes_on_the_cartridge_when_asked
    seen = []
    test = self
    watching = VBlank::Playthroughs::Playthrough.new("watch the passes") do
      wait_until("a while has gone by", within: FRAMES_READ + 1) do |game|
        seen << test.reading_of(game)
        seen.length > FRAMES_READ
      end
    end
    watching.play(cartridge, count_passes: true)

    assert_passes_are_the_games_own(seen)
  end

  def test_a_script_that_does_not_steer_counts_nothing_on_the_cartridge_and_says_how_to
    played = VBlank::Playthroughs::Playthrough.new("wait") { wait frames: 5 }.play(cartridge)

    error = assert_raises(ArgumentError) { played.game.passes }
    assert_match(/count_passes: true/, error.message)
  end

  def test_a_cartridge_file_has_no_names_to_ask
    Dir.mktmpdir do |dir|
      path = File.join(dir, "reads.gba")
      File.binwrite(path, cartridge.buffer)
      played = VBlank::Playthroughs::Playthrough.new("wait") { wait frames: 5 }.play(path)

      error = assert_raises(ArgumentError) { played.game.var?(:done) }
      assert_match(/not built here/, error.message)
    end
  end
end
