# frozen_string_literal: true

require "test_helper"
require "all/vblank/playthroughs/test_tape_until"

# A tape of passes with `until` lines on every way a tape plays: the cartridge in the emulator and
# each way that runs the game itself. Recorded on the build with the quick fade, it is played on the
# build with the slow one, which none of its counts know about.
class TestPlaythroughUntil < Minitest::Test
  include TapeUntilGames

  private def recorded = to_the_play.play(quick_fade, in_passes: :steps, on: "interpreter").tape

  VBlank::Playthroughs::LoweredGame.ways.each do |way|
    define_method(:"test_a_tape_of_until_steps_plays_to_the_play_on_#{way}", &Ractor.shareable_proc {
      slow = way == VBlank::Playthroughs::LoweredGame::EMULATOR ? until_cartridge(fade_step: 3) : slow_fade
      game = recorded.play(slow, on: way).game

      assert_equal [PLAYING, 5], [game.var(:screen), game.var(:x)]
    })
  end

  def test_a_recording_on_the_cartridge_plays_on_the_interpreter
    on_the_cartridge = to_the_play.play(until_cartridge(fade_step: 25), in_passes: :steps).tape

    assert_equal recorded, on_the_cartridge.with(title: recorded.title, checksum: recorded.checksum)
    assert_equal 5, on_the_cartridge.play(slow_fade, on: "interpreter").game.var(:x)
  end

  def test_in_frames_writes_the_frames_each_until_step_took_on_that_cartridge
    cartridge = until_cartridge(fade_step: 3)
    frames = recorded.in_frames_on(cartridge)

    refute_includes frames.to_s, "until"
    assert_equal 5, frames.play(cartridge).game.var(:x)
  end

  def test_a_bot_refuses_a_tape_that_waits_on_the_game
    error = assert_raises(ArgumentError) { VBlank::Bots::TapeBot.new(recorded, player: 1) }

    assert_match(/until/, error.message)
  end
end
