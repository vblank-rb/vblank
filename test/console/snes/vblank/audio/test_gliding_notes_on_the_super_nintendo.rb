# frozen_string_literal: true

require "test_helper"

# ONE RECORDED NOTE MOVING THROUGH EXACT PITCHES, struck once. A recording that runs for 40 frames at
# its own pitch is the clock here: read twice as fast from half way it ends at 30, and a note struck
# again would start over and last until 40 or past it.
class TestGlidingNotesOnTheSuperNintendo < Minitest::Test
  Score = VBlank::Audio::Score
  ROOT = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(:C4)
  RATE = 8000
  FRAMES = 40

  private def effect(*notes)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE * FRAMES / 60 / 2), rate: RATE, note: :C4
      sfx = sound_effects :sfx, { chirp: Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4) }
      passes = var :passes, 0
      game_loop do
        passes += 1
        sfx.play 0 if passes == 2
      end
    end
    b.finalize_program
    b.program
  end

  # A tick is six frames at this tempo, so the second note comes 18 frames in. Its length keeps the
  # effect going past the recording's end, so that the recording ending is what is measured.
  private def second_note(**said) = Score::Note.new(at: 3, hz: ROOT * 2, length: 20, **said)

  # The same notes as a song, which the music's player walks and not the effects'.
  private def song_of(*notes)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE * FRAMES / 60 / 2), rate: RATE, note: :C4
      music = songs :music, [Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4, plays_once: true)]
      music.play 0
      game_loop { nil }
    end
    b.finalize_program
    b.program
  end

  def test_a_song_note_that_glides_reads_on_too
    steady = song_of(Score::Note.new(at: 0, hz: ROOT, length: 23))
    glided = song_of(Score::Note.new(at: 0, hz: ROOT), second_note(glides: true))

    assert_operator frame_it_ends(glided), :<, frame_it_ends(steady)
  end

  # The frame the note stops sounding, played a frame at a time.
  private def frame_it_ends(program)
    (1..60).find { |frames| frames > 3 && game_player.run(program, frames: frames).active_samples.empty? }
  end

  def test_a_note_that_glides_reads_on_from_where_it_was_at_its_new_pitch
    steady = effect(Score::Note.new(at: 0, hz: ROOT, length: 23))
    glided = effect(Score::Note.new(at: 0, hz: ROOT), second_note(glides: true))

    assert_operator frame_it_ends(glided), :<, frame_it_ends(steady)
  end

  def test_a_note_struck_again_starts_over
    glided = effect(Score::Note.new(at: 0, hz: ROOT), second_note(glides: true))
    struck = effect(Score::Note.new(at: 0, hz: ROOT), second_note)

    assert_operator frame_it_ends(glided), :<, frame_it_ends(struck)
  end
end
