# frozen_string_literal: true

require "test_helper"

# A GLIDING NOTE ON THE SOUND CHIP. The checked run holds where the note has got to against the
# interpreter, but what is heard is the chip's voice, so these read its pitch registers.
class TestSNESGlidingNotes < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  VOICE = 4 << 4 # the first voice recordings play on
  ENVX = 0x8
  ROOT = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(:C4)
  RATE = 32_000 # the chip's own: pitch $1000 reads such a recording as recorded

  # The note that sounds the chip's own pitch number +pitch+ on this recording.
  private def hz_of(pitch) = ROOT * pitch / 4096.0

  private def played(notes, frames:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE / 2), rate: RATE, note: :C4
      sfx = sound_effects :sfx, { chirp: Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4) }
      passes = var :passes, 0
      game_loop do
        passes += 1
        sfx.play 0 if passes == 2
      end
    end
    b.finalize_program
    SNES::CheckedRun.new.run(b.program, frames: frames)
  end

  private def pitch_of(run)
    dsp = run.dsp_registers
    dsp.getbyte(VOICE + 2) | (dsp.getbyte(VOICE + 3) << 8)
  end

  # Pitches no key reaches, on the chip to the step.
  def test_a_glide_reaches_the_voice_pitch_exactly
    notes = [Score::Note.new(at: 0, hz: hz_of(0xF38)), Score::Note.new(at: 3, hz: hz_of(0x1964), length: 20, glides: true)]

    assert_equal 0xF38, pitch_of(played(notes, frames: 10)), "before the glide"
    assert_equal 0x1964, pitch_of(played(notes, frames: 30)), "after the glide"
  end

  # The left and right volumes of the voice.
  private def volumes_of(run) = [run.dsp_registers.getbyte(VOICE), run.dsp_registers.getbyte(VOICE + 1)]

  # A glide with a volume and a side of its own: the voice's two volumes are the glide's, the near side at
  # its loudness and the far side turned down, as a note struck there would be, with no key-on.
  def test_a_glide_takes_its_own_loudness_and_side
    loud = Score::Note.new(at: 0, hz: hz_of(0x1000), volume: 15)
    glided = played([loud, Score::Note.new(at: 3, hz: hz_of(0x1000), volume: 6, pan: -0.5, length: 20, glides: true)], frames: 30)
    struck = played([loud, Score::Note.new(at: 3, hz: hz_of(0x1000), volume: 6, pan: -0.5, length: 20)], frames: 30)
    left, right = volumes_of(glided)

    assert_operator left, :<, volumes_of(played([loud], frames: 30)).first, "quieter than the note it carried on"
    assert_equal (left * 32 / 64.0).round, right, "the right turned down by half"
    assert_equal volumes_of(struck), [left, right], "as a note struck there"
  end

  # A SONG FADING OUT while its recorded note glides with no volume or side of its own: the note keeps
  # the side it was struck at and falls with the music, as the interpreter's loudness falls.
  private def fading_song
    notes = [Score::Note.new(at: 0, hz: hz_of(0x1000), volume: 9, pan: -0.5, length: 40),
             *[2, 4, 6].map { |tick| Score::Note.new(at: tick, hz: hz_of(0x1000 + (tick * 0x40)), glides: true) }]
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE / 2), rate: RATE, note: :C4
      music = songs :music, [Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4)]
      passes = var :passes, 0
      game_loop do
        passes += 1
        music.play 0
        fade_music_out frames: 30 if passes == 20
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_glide_under_a_fading_music_volume_keeps_its_side_and_falls_with_the_music
    program = fading_song
    loudness = ->(frames) { VBlank::IR::Backends::Reference.new.run(program, frames: frames).loudness_by_voice.first }
    before_left, before_right = volumes_of(SNES::CheckedRun.new.run(program, frames: 10))

    assert_equal (before_left * 32 / 64.0).round, before_right, "struck to the left"
    [30, 40].each do |frames|
      left, right = volumes_of(SNES::CheckedRun.new.run(program, frames: frames))

      assert_in_delta (left * 32 / 64.0), right, 1, "frame #{frames}: still to the left (#{left}, #{right})"
      assert_in_delta before_left * loudness.call(frames) / loudness.call(10).to_f, left, 2,
                      "frame #{frames}: falling with the music as the interpreter's loudness does"
    end
  end

  def test_a_glide_with_nothing_sounding_stays_silent
    run = played([Score::Note.new(at: 3, hz: hz_of(0x1964), length: 20, glides: true)], frames: 30)

    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
    assert_empty run.active_samples
  end
end
