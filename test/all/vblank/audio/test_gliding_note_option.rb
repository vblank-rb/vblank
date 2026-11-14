# frozen_string_literal: true

require "test_helper"

# Which notes can say `glides:`, in a Score and in a `song` block. What it does is
# test/gliding_note_tests.rb, played by each console that glides, and what a console that
# cannot do it says is test/all/vblank/ir/guardrails/test_glides_refused.rb.
class TestGlidingNoteOption < Minitest::Test
  Score = VBlank::Audio::Score

  private def error_of(note, **part)
    assert_raises(ArgumentError) { Score.new(parts: [Score::Part.new(notes: [note], **part)]).to_song }
  end

  def test_only_true_or_false_is_taken
    assert_match(/true or false/, error_of(Score::Note.new(at: 0, key: :C4, glides: :yes), plays: :tone).message)
  end

  def test_a_square_part_cannot_glide
    assert_match(/plays a recording/, error_of(Score::Note.new(at: 0, key: :C4, glides: true)).message)
  end

  def test_a_note_that_glides_says_nothing_but_its_pitch
    [{ instrument: :other }, { volume: 8 }, { envelope: { attack: 1, decay: 1, sustain: 8, release: 1 } }].each do |said|
      note = Score::Note.new(at: 0, key: :C4, glides: true, **said)

      assert_match(/carries on/, error_of(note, plays: :tone).message, said.keys.first.to_s)
    end
  end

  # A `song` block's note that glides: refused where the Score's is, in the same words.
  private def song_block_error(plays: :tone, **said)
    b = Builder.new
    assert_raises(ArgumentError) do
      b.instance_eval do
        instrument :tone, pcm: [60, -60] * 40, rate: 8000, note: :C4
        song(:tune) { voice(:keys, plays: plays) { |v| v.note :C4, :quarter, glides: true, **said } }
      end
    end
  end

  def test_a_song_blocks_square_part_cannot_glide
    assert_match(/plays a recording/, song_block_error(plays: nil).message)
  end

  def test_a_song_blocks_note_that_glides_says_nothing_but_its_pitch
    assert_match(/carries on/, song_block_error(volume: 8).message)
    assert_match(/carries on/, song_block_error(envelope: { release: 0.2 }).message)
  end

  def test_a_song_blocks_glides_is_true_or_false
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        instrument :tone, pcm: [60, -60] * 40, rate: 8000, note: :C4
        song(:tune) { voice(:keys, plays: :tone) { |v| v.note :C4, :quarter, glides: :yes } }
      end
    end

    assert_match(/true or false/, error.message)
  end

  def test_a_recordings_hz_out_of_range_is_told_as_a_pitch
    assert_match(/pitch of the note/, error_of(Score::Note.new(at: 0, hz: -1), plays: :tone).message)
  end
end
