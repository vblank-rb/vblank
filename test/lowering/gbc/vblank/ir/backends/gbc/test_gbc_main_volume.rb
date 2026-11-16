# frozen_string_literal: true

require "test_helper"

# THE MAIN VOLUME (`enable_sound main_volume:`) AS THE COLOR'S CARTRIDGE WRITES IT: NR50, a level for
# each speaker from an eighth to eight eighths (GameBoySound.speaker_level says how a number of 127ths
# is taken to it), read in the emulator and heard from its speaker.
class TestGBCMainVolume < Minitest::Test
  H = VBlank::Console::GBCHardware

  POWER_ON = 0x80

  # A held note of a song and a beep that holds, under +main_volume+ (nil: the game names none).
  private def song_and_beep(main_volume)
    VBlank.game("MAINVOLUME", consoles: %i[gbc]) do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      beep :hum
      game_loop { play_song :tune }
    end.program(console: :gbc)
  end

  # NR50 and NR52 once the game has played a few frames.
  private def registers(main_volume)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(song_and_beep(main_volume), title: "MAINVOLUME")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 12)
    [v.mem8(H::NR50), v.mem8(H::NR52)]
  end

  # The loudest frame the speaker plays, past the first few, while the Color's speaker settles.
  private def loudest_heard(main_volume)
    heard = VBlank::Diagnostics::SoundRecording.of(song_and_beep(main_volume), on: :cartridge, frames: 40)
    heard.frames.drop(20).map(&:loudness).max
  end

  def test_a_game_that_names_none_plays_at_the_loudest
    assert_equal 0x77, registers(nil).first & 0x77
  end

  # 96/127 is nearest six eighths.
  def test_the_main_volume_named_is_in_both_speakers_levels
    assert_equal 0x55, registers(96).first & 0x77
  end

  def test_a_share_of_a_half_is_four_eighths
    assert_equal 0x33, registers(0.5).first & 0x77
  end

  # 10/127 is nearer an eighth than nothing, the quietest the level goes.
  def test_a_quiet_main_volume_is_the_quietest_level
    assert_equal 0x00, registers(10).first & 0x77
  end

  # Nothing at all: the sound chip is left switched off, since the quietest level is still an eighth.
  def test_a_main_volume_of_nothing_leaves_the_sound_off
    refute registers(0).last.anybits?(POWER_ON)
    assert_operator loudest_heard(0), :<, loudest_heard(nil) / 50
  end

  def test_the_song_and_the_beep_are_heard_at_the_level_written
    assert_in_delta 6 / 8.0, loudest_heard(96).fdiv(loudest_heard(nil)), 0.03
  end
end
