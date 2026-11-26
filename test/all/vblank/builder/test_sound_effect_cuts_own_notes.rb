# frozen_string_literal: true

require "test_helper"

# `cuts_own_notes: true` on an effect's Score: each recorded note of a part takes the voice of the
# part's note before it, as a cartridge's sound driver keys a part's notes on one voice. What it
# does to the voices is played on each console that mixes recordings, in
# test/sound_effect_recording_tests.rb; here, what the build refuses.
class TestSoundEffectCutsOwnNotes < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  private def score(cuts) = Score.new(cuts_own_notes: cuts, parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])])

  def test_a_game_whose_effects_cut_their_notes_apart_is_refused
    scores = { a: score(true), b: score(false) }
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { sound_effects :sfx, scores } }

    assert_match(/all cut their own notes, or none does/, error.message)
  end

  def test_a_song_that_cuts_its_notes_is_refused
    scores = [score(true)]
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { songs :music, scores } }

    assert_match(/It is for a sound effect/, error.message)
  end

  def test_a_score_whose_cuts_own_notes_is_not_true_or_false_is_refused
    assert_raises(ArgumentError) { score(:yes).to_song }
  end
end
