# frozen_string_literal: true

require "test_helper"

# A RECORDED PART THAT SITS BETWEEN THE SPEAKERS, on the PlayStation. Each voice of its sound chip has
# a volume for the left speaker and one for the right, so a part's shade is heard as it was given: the
# near side at the note's loudness, the far side less by how far off the middle it sits (Audio::Pan).
class TestPS1RecordedPan < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  SPU = PS1::SPUWrites
  H = VBlank::Console::PS1Hardware
  VOICE = PS1::Runtime::Recordings::FIRST_VOICE # the first place's voice, the only one this tune takes

  private def tune_game(pan:, note_pan: nil, envelope: nil)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :tune do
        tempo 150
        voice :melody, plays: :tone, envelope: envelope do
          pan(pan) if pan
          volume 15
          note :C4, :whole, pan: note_pan
        end
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The [left, right] volume of the voice sounding the tune, after +frames+.
  private def volumes(program, frames: 6)
    registers = PS1::CheckedRun.new.run(program, frames: frames).spu_reads.last.last
    [registers[SPU.register(VOICE, H::SPU_VOLUME_LEFT)], registers[SPU.register(VOICE, H::SPU_VOLUME_RIGHT)]]
  end

  private def whole = volumes(tune_game(pan: nil)).first

  def test_a_part_in_the_middle_is_heard_alike_from_both_sides
    left, right = volumes(tune_game(pan: nil))

    assert_operator left, :>, 0
    assert_equal left, right
  end

  def test_a_shade_to_the_left_turns_the_right_side_down
    assert_equal [whole, (whole * 19 / 64.0).round], volumes(tune_game(pan: -0.7))
  end

  def test_a_note_sits_where_it_says_in_a_part_that_sits_elsewhere
    assert_equal [whole, 0], volumes(tune_game(pan: :right, note_pan: :left))
  end

  def test_a_shaped_note_keeps_its_shade_as_it_climbs
    envelope = { attack: 0.5, decay: 0.5, sustain: 0.5 }
    centred = volumes(tune_game(pan: nil, envelope: envelope), frames: 4).first
    left, right = volumes(tune_game(pan: 0.5, envelope: envelope), frames: 4)

    assert_equal [(centred * 32 / 64.0).round, centred], [left, right]
  end
end
