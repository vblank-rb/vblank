# frozen_string_literal: true

require "test_helper"
require "recorded_fraction_volume_tests"

# A recorded note whose volume holds a fraction, on the Super Nintendo's sound chip. A voice's volume
# register runs 0 to 127 (fullsnes, "SNES APU DSP Volume Registers"), so a note of loudness L 512ths
# is set to L x 127 / 512, the nearest step: a sound driver that writes 110 or 124 there is matched
# by a loudness of 444 or 500, where the sixteen whole volumes give only 119 and 127.
class TestSNESRecordedFractionVolumes < Minitest::Test
  include RecordedFractionVolumeGames

  SNES = VBlank::IR::Backends::SNES
  VOICES = 8
  PITCH = 0x1000 # a 32,000-a-second recording played at its own note

  # The [left, right] volume of the voice sounding the recording, after +frames+.
  private def volumes(program, frames: 8)
    dsp = SNES::CheckedRun.new.run(program, frames: frames).dsp_registers
    voice = (0...VOICES).find { |v| dsp.getbyte((v << 4) + 2) | (dsp.getbyte((v << 4) + 3) << 8) == PITCH }
    assert voice, "no voice sounds the recording"
    [dsp.getbyte(voice << 4), dsp.getbyte((voice << 4) + 1)]
  end

  private def snes_builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))

  def test_a_song_note_of_loudness_444_sets_its_voice_to_110
    assert_equal [110, 110], volumes(fraction_game(444, as: :song, builder: snes_builder))
  end

  def test_a_sound_effect_note_of_loudness_500_sets_its_voice_to_124
    assert_equal [124, 124], volumes(fraction_game(500, as: :effect, builder: snes_builder))
  end
end
