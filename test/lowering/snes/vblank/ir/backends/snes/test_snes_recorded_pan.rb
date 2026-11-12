# frozen_string_literal: true

require "test_helper"

# A RECORDED PART THAT SITS BETWEEN THE SPEAKERS, on the Super Nintendo. Each voice of its sound chip
# has a volume for the left speaker and one for the right (VOL L and VOL R), so a part's shade is
# heard as it was given: the near side at the note's loudness, the far side less by how far off the
# middle it sits (Audio::Pan), as a console game's own tunes set their recorded voices.
#
# The music's notes reach the chip three ways, each written apart in Runtime::Recordings: told a
# register at a time, queued behind the frame's other writes, and in a game with sound effects told
# whole to the sound unit's own program. A game of each is played here.
class TestSNESRecordedPan < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  RATE = 32_000 # the chip's own rate: pitch $1000 reads such a recording as recorded
  VOICES = 8
  PITCH = 0x1000

  private def tune_game(pan:, note_pan: nil, effects: false, envelope: nil)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE / 2), rate: RATE, note: :C4
      sfx = sound_effects(:sfx, { chirp: VBlank::Audio::Score.new(
        parts: [VBlank::Audio::Score::Part.new(notes: [VBlank::Audio::Score::Note.new(at: 0, key: :C6)])], tempo: 150
      ) }) if effects
      song :tune do
        tempo 150
        voice :melody, plays: :tone, envelope: envelope do
          pan(pan) if pan
          volume 15
          note :C4, :whole, pan: note_pan
        end
      end
      play_song :tune
      if sfx
        passes = var :passes, 0
        game_loop do
          passes += 1
          sfx.play 0 if passes == 2
          wait_vblank
        end
      else
        game_loop { wait_vblank }
      end
    end
    b.finalize_program
    b.program
  end

  # The [left, right] volume of the voice sounding the recording at its own pitch, after +frames+.
  private def volumes(program, frames: 6)
    dsp = SNES::CheckedRun.new.run(program, frames: frames).dsp_registers
    voice = (0...VOICES).find { |v| dsp.getbyte((v << 4) + 2) | (dsp.getbyte((v << 4) + 3) << 8) == PITCH }
    assert voice, "no voice sounds the recording"
    [dsp.getbyte(voice << 4), dsp.getbyte((voice << 4) + 1)]
  end

  # The loudness a note of this tune is heard at from the middle, on both sides.
  private def whole = volumes(tune_game(pan: nil)).first

  def test_a_part_in_the_middle_is_heard_alike_from_both_sides
    left, right = volumes(tune_game(pan: nil))

    assert_operator left, :>, 0
    assert_equal left, right
  end

  def test_a_shade_to_the_left_turns_the_right_side_down
    assert_equal [whole, (whole * 19 / 64.0).round], volumes(tune_game(pan: -0.7))
  end

  def test_a_shade_to_the_right_turns_the_left_side_down
    assert_equal [(whole * 16 / 64.0).round, whole], volumes(tune_game(pan: 0.75))
  end

  def test_a_note_sits_where_it_says_in_a_part_that_sits_elsewhere
    assert_equal [0, whole], volumes(tune_game(pan: :left, note_pan: :right))
  end

  def test_a_shaded_part_is_heard_where_it_sits_in_a_game_with_sound_effects
    assert_equal [whole, (whole * 19 / 64.0).round], volumes(tune_game(pan: -0.7, effects: true), frames: 8)
  end

  # A square part beside it at a shade plays from the nearest side, as on every console: its voice
  # (the first) has no volume on the other.
  def test_a_shaded_square_part_beside_it_plays_from_the_nearest_side
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE / 2), rate: RATE, note: :C4
      song :tune do
        tempo 150
        voice(:lead) { |v| v.pan 0.7; v.note :C5, :whole }
        voice(:melody, plays: :tone) { |v| v.pan(-0.7); v.volume 15; v.note :C4, :whole }
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    dsp = SNES::CheckedRun.new.run(b.program, frames: 6).dsp_registers

    assert_equal 0, dsp.getbyte(0), "the square voice has nothing on the left"
    assert_operator dsp.getbyte(1), :>, 0, "and is heard on the right"
    assert_equal [whole, (whole * 19 / 64.0).round], volumes(b.program)
  end

  # A note with a shape has its loudness worked out every frame as it climbs and falls, and each
  # side keeps its share of it.
  def test_a_shaped_note_keeps_its_shade_as_it_climbs
    envelope = { attack: 0.5, decay: 0.5, sustain: 0.5 }
    centred = volumes(tune_game(pan: nil, envelope: envelope), frames: 4).first
    left, right = volumes(tune_game(pan: -0.5, envelope: envelope), frames: 4)

    assert_equal centred, left
    assert_equal (centred * 32 / 64.0).round, right
  end
end
