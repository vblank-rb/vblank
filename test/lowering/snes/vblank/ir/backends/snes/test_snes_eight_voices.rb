# frozen_string_literal: true

require "test_helper"

# THE SOUND CHIP HAS EIGHT VOICES, and a game with no use for the square, wave and noise parts has
# all eight for its recordings. Read on the cartridge's own sound chip: a voice whose envelope is
# above nothing is sounding.
class TestSNESEightVoices < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  ENVX = 0x8

  private def voices_sounding(program, frames:)
    dsp = SNES::CheckedRun.new.run(program, frames: frames).dsp_registers
    (0...8).count { |voice| dsp.getbyte((voice << 4) + ENVX).positive? }
  end

  # A song of +parts+ parts that play a recording, and whatever the block adds to the game.
  private def recorded_song_game(parts, &also)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100
      song(:title) { parts.times { |part| voice(:"part#{part}", plays: :piano) { note :C4, :whole } } }
      play_song :title
      instance_exec(&also) if also
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_song_of_eight_recorded_parts_sounds_on_eight_voices
    assert_equal 8, voices_sounding(recorded_song_game(8), frames: 6)
  end

  def test_a_seven_part_title_tune_plays_every_part
    assert_equal 7, voices_sounding(recorded_song_game(7), frames: 6)
  end

  # A square part keeps its voice, so one recording fewer is heard, though it is still counted.
  def test_a_voice_a_game_uses_itself_is_not_taken_for_a_recording
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100
      song(:title) do
        voice(:square) { note :E4, :whole }
        7.times { |part| voice(:"part#{part}", plays: :piano) { note :C4, :whole } }
      end
      play_song :title
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal 8, voices_sounding(b.program, frames: 6), "the square, and seven recordings"
  end

  def test_a_sound_effect_cuts_in_over_a_full_song
    program = recorded_song_game(7) do
      score = VBlank::Audio::Score
      effect = score.new(tempo: 150, priority: 1, parts: [score::Part.new(plays: :piano, notes: [score::Note.new(at: 0, key: :A4, length: 24)])])
      sounds = sound_effects :sfx, { ding: effect }
      sounds.play :ding
    end

    assert_equal 8, voices_sounding(program, frames: 6)
  end
end
