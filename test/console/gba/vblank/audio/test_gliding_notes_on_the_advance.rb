# frozen_string_literal: true

require "test_helper"
require "mixed_sound"
require "gliding_note_tests"

# A recorded note that glides, played as the Advance (the tests every console that glides plays are
# in test/gliding_note_tests.rb), and the sound the Advance's mix makes of one, byte for byte against
# the interpreter's: the cartridge on the gba run, the game as C, JavaScript and Ruby on theirs.
class TestGlidingNotesOnTheAdvance < Minitest::Test
  include GlidingNoteTests
  include MixedSound

  # A part that bends its note up and down while it sounds, a glide every six frames four times and
  # then two more, then a note struck from the left speaker, which the Advance's one mix plays from
  # both. +envelope+ shapes the part's notes; +volume_at+ moves the music volume on that pass.
  private def bending_song(envelope: nil, volume_at: nil)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: (0...4000).map { |n| ((n % 23) * 9) - 100 }, rate: 8000, note: :C4
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        voice(:keys, plays: :tone, envelope: envelope) do |v|
          v.note :C4, :eighth
          4.times { |n| v.note 262 + (n * 10), :sixteenth, glides: true }
          v.note :E4, :eighth, glides: true
          v.note :D4, :eighth, glides: true
          v.note :G4, :quarter, pan: :left
          v.rest :half
        end
      end
      play_song :tune
      pass = var :pass, 0
      game_loop do
        pass += 1
        music_volume 50 if volume_at && pass == volume_at
      end
    end
    b.finalize_program
    b.program
  end

  # The same bends as a sound effect's, which the effects' player walks.
  private def bending_effect
    notes = [Score::Note.new(at: 0, key: :C4), Score::Note.new(at: 2, key: :E4, glides: true),
             Score::Note.new(at: 4, hz: 300, glides: true, length: 4)]
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: (0...4000).map { |n| ((n % 23) * 9) - 100 }, rate: 8000, note: :C4
      sfx = sound_effects :sfx, { bend: Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4) }
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :bend if pass == 2
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_bending_note_mixes_alike
    assert_mixes_agree bending_song, frames: 80, at_least: 60
  end

  def test_a_bending_shaped_note_mixes_alike
    assert_mixes_agree bending_song(envelope: { attack: 0.05, release: 0.2 }), frames: 80, at_least: 60
  end

  def test_a_bending_note_under_a_moved_music_volume_mixes_alike
    assert_mixes_agree bending_song(volume_at: 10), frames: 80, at_least: 60
  end

  def test_a_sound_effects_bending_note_mixes_alike
    assert_mixes_agree bending_effect, frames: 60, at_least: 30
  end

  # A SONG THAT COMES ROUND TO A NOTE IT HOLDS, bent the frame after: the held note is on a recording
  # of its own (the harp, not the part's tone), and the glide reads that recording faster each time
  # round. A tick is a frame; the song is 30 frames and comes round to frame 10, so the bend at 11
  # plays on the first pass and again at 31 and 51.
  private def bent_after_coming_round
    notes = [Score::Note.new(at: 0, key: :C4), Score::Note.new(at: 6, key: :E4, instrument: :harp),
             Score::Note.new(at: 11, key: :G4, glides: true), Score::Note.new(at: 20, key: :A4)]
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: (0...4000).map { |n| ((n % 23) * 9) - 100 }, rate: 8000, note: :C4
      instrument :harp, pcm: (0...4000).map { |n| ((n % 31) * 6) - 90 }, rate: 11_025, note: :C4
      music = songs :music, [Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 24,
                                       length: 30, loop_from: 10)]
      music.play 0
      game_loop { nil }
    end
    b.finalize_program
    b.program
  end

  def test_a_glide_after_the_song_comes_round_mixes_alike
    assert_mixes_agree bent_after_coming_round, frames: 70, at_least: 60
  end
end
