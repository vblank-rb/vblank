# frozen_string_literal: true

require "test_helper"

# The main volume (`enable_sound main_volume:`) as the Advance's cartridge writes it, read from its
# sound registers in the emulator and heard from its speaker. The Game Boy voices are scaled twice:
# by SOUNDCNT_L's level for each speaker, an eighth to eight eighths, and by SOUNDCNT_H's share for
# them all, a quarter, a half or the whole; the recordings by SOUNDCNT_H's bit for channel A, half
# or the whole (GBA::MainVolume says how a number of 127ths is taken to them).
class TestGBAMainVolume < Minitest::Test
  H = VBlank::Console::Hardware

  POWER_ON = H::SOUND_MASTER_ENABLE
  RECORDINGS_FULL = H::DSOUND_A_VOLUME_FULL
  PSG_SHARE_BITS = 0x0003

  # A held note of a song and a beep that holds, under +main_volume+ (nil: the game names none),
  # and, with +recording+, a recording looping beside them.
  private def song_and_beep(main_volume, recording: false)
    VBlank.game("MAINVOLUME", consoles: %i[gba]) do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      drone = sample(:drone, pcm: Array.new(2000) { |i| ((i * 9) % 200) - 100 }, rate: 8000) if recording
      beep :hum
      drone&.play(loop: true)
      game_loop { play_song :tune }
    end.program(console: :gba)
  end

  # SOUNDCNT_L, SOUNDCNT_H and SOUNDCNT_X once the game has played a few frames.
  private def registers(program)
    v = assert_emulator_loads_rom(assemble_rom(program, name: "MAINVOLUME"), frames: 10)
    [v.mem16(H::REG_SOUNDCNT_L), v.mem16(H::REG_SOUNDCNT_H), v.mem16(H::REG_SOUNDCNT_X)]
  end

  # The loudest frame the speaker plays, past the first few.
  private def loudest_heard(program)
    VBlank::Diagnostics::SoundRecording.of(program, on: :cartridge, frames: 30).frames.drop(10).map(&:loudness).max
  end

  def test_a_game_that_names_none_plays_at_the_loudest
    speakers, mixing, power = registers(song_and_beep(nil, recording: true))

    assert_equal 0x77, speakers & 0xFF
    assert_equal 2, mixing & PSG_SHARE_BITS
    assert mixing.anybits?(RECORDINGS_FULL)
    assert power.anybits?(POWER_ON)
  end

  # 96/127 is nearest six eighths at the whole share; the recordings at the whole, the nearer of two.
  def test_the_main_volume_named_is_in_the_speakers_level
    speakers, mixing, = registers(song_and_beep(96, recording: true))

    assert_equal 0x55, speakers & 0xFF
    assert_equal 2, mixing & PSG_SHARE_BITS
    assert mixing.anybits?(RECORDINGS_FULL)
  end

  # Half is four eighths at the whole share; the recordings at half.
  def test_a_share_of_a_half_halves_the_voices_and_the_recordings
    speakers, mixing, = registers(song_and_beep(0.5, recording: true))

    assert_equal 0x33, speakers & 0xFF
    assert_equal 2, mixing & PSG_SHARE_BITS
    refute mixing.anybits?(RECORDINGS_FULL)
  end

  # 10/127 is nearest three eighths of a quarter, quieter than the speakers' level goes alone.
  def test_a_quiet_main_volume_takes_the_quarter_share
    speakers, mixing, = registers(song_and_beep(10))

    assert_equal 0x22, speakers & 0xFF
    assert_equal 0, mixing & PSG_SHARE_BITS
  end

  # Nothing at all: the sound is left switched off, since the quietest level is still an eighth.
  def test_a_main_volume_of_nothing_leaves_the_sound_off
    program = song_and_beep(0, recording: true)
    _, _, power = registers(program)

    refute power.anybits?(POWER_ON)
    assert_operator loudest_heard(program), :<, loudest_heard(song_and_beep(nil, recording: true)) / 50
  end

  # The square voices, heard: six eighths of the loudest.
  def test_the_song_and_the_beep_are_heard_at_the_level_written
    full, quieter = [nil, 96].map { |main_volume| loudest_heard(song_and_beep(main_volume)) }

    assert_in_delta 6 / 8.0, quieter.fdiv(full), 0.03
  end
end
