# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "sound_name_tests"

class TestSoundNames < Minitest::Test
  include SoundNameTests

  private def console = :gba

  # A game whose effects are on a timer of their own plays them only on its ticks, several in one
  # frame at times; an effect still starts on one frame and is named on it. At 300 beats a minute
  # and 24 ticks a beat, the timer ticks twice a frame.
  def test_effects_on_a_timer_are_named_on_the_frame_the_interpreter_names
    blip = Score.new(tempo: 300, on_timer: true, parts: [Part.new(notes: [Note.new(at: 0, key: :C5)])], length: 6)
    built = VBlank.build("TIMEDNAMES", console: :gba, out: nil, err: nil) do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { blip: blip }
      pass = 0
      game_loop do
        pass += 1
        sfx.play :blip if pass == 3
        sfx.play :blip if pass == 4
        sfx.play :blip if pass == 9
      end
    end

    assert_equal interpreted(built), cartridge(built).first(FRAMES)
  end

  def test_a_game_with_no_sound_names_none
    built = VBlank.build("QUIETNAMES", console: :gba, out: nil, err: nil) do
      screen :bitmap
      game_loop { nil }
    end

    assert_equal [[1, [], nil], [2, [], nil]], cartridge_frames(built, 2)
  end

  def test_a_cartridge_file_has_no_names
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gba")
      named_sound_game.write(path)
      reader = VBlank::Diagnostics::Verifier.new(VBlank::Diagnostics::CartridgeFile.new(path), frames: 2)

      assert_match(/not built here/, assert_raises(ArgumentError) { reader.watch_sound_names }.message)
    end
  end

  private def cartridge_frames(built, frames)
    reader = VBlank::Diagnostics::Verifier.new(built, frames: frames + 1)
    reader.watch_sound_names
    reader.sound_names_by_frame.map { |heard| [heard.frame, heard.effects, heard.song] }
  end
end
