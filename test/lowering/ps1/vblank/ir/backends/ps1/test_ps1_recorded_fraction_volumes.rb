# frozen_string_literal: true

require "test_helper"
require "recorded_fraction_volume_tests"

# A recorded note whose volume holds a fraction, on the PlayStation's sound chip. A voice's volume
# register has far more steps than the mix's 512 (psx-spx, "SPU Voice Volume"), so a note of loudness
# L 512ths is set to exactly L 512ths of a whole note's volume.
class TestPS1RecordedFractionVolumes < Minitest::Test
  include RecordedFractionVolumeGames

  PS1 = VBlank::IR::Backends::PS1
  SPU = PS1::SPUWrites
  H = VBlank::Console::PS1Hardware
  VOICE = PS1::Runtime::Recordings::FIRST_VOICE # the first place's voice, the only one these games take

  # The [left, right] volume of the voice sounding the note, after +frames+.
  private def volumes(program, frames: 8)
    registers = PS1::CheckedRun.new.run(program, frames: frames).spu_reads.last.last
    [registers[SPU.register(VOICE, H::SPU_VOLUME_LEFT)], registers[SPU.register(VOICE, H::SPU_VOLUME_RIGHT)]]
  end

  private def ps1_builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))

  private def at_loudness(loudness, as:) = volumes(fraction_game(loudness, as: as, builder: ps1_builder))

  def test_a_song_note_of_loudness_444_is_444_512ths_of_a_whole_note
    whole = at_loudness(512, as: :song).first

    assert_operator whole, :>, 0
    assert_equal [whole * 444 / 512] * 2, at_loudness(444, as: :song)
  end

  def test_a_sound_effect_note_of_loudness_500_is_500_512ths_of_a_whole_note
    whole = at_loudness(512, as: :effect).first

    assert_operator whole, :>, 0
    assert_equal [whole * 500 / 512] * 2, at_loudness(500, as: :effect)
  end
end
