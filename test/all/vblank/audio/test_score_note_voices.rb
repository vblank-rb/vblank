# frozen_string_literal: true

require "test_helper"

# A drum part whose hits rattle on some notes and not on others, and a wave part that changes its
# waveform between notes, as a song converted from another Game Boy game has them. Kept once for
# this file and for each console's test of what its cartridge writes (the Advance's
# test/lowering/gba/vblank/audio/test_score_note_voices_cartridge.rb, the Color's
# test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_note_voices.rb).
module ScoreNoteVoicesGames
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # A waveform of the game's own: a square of 32 steps, low then high.
  STEPPED = Ractor.make_shareable(([2] * 16) + ([13] * 16))

  # At 150 beats a minute and 24 ticks a beat a tick is a frame, so a note's tick is the frame it
  # sounds on. Each note lasts five frames and rests three, so each voice rests between notes.
  NOTE_TICKS = [0, 8, 16, 24].freeze
  LENGTH = 5

  # Whether each drum hit rattles: its own word, then its part's (plain) on the last.
  RATTLES = [true, false, true, nil].freeze

  # The waveform each wave note plays: its own, then its part's (:sawtooth) on the third.
  WAVES = Ractor.make_shareable([:sine, STEPPED, nil, :sine])
  PART_WAVE = :sawtooth

  # The song: the drum part and the wave part, forty frames long.
  private def rattle_and_wave_song
    drums = NOTE_TICKS.zip(RATTLES).map { |at, rattles| Note.new(at: at, length: LENGTH, key: 60, metallic: rattles) }
    pad = NOTE_TICKS.zip(WAVES).map { |at, wave| Note.new(at: at, length: LENGTH, key: 57, wave: wave) }
    Score.new(tempo: 150, length: 40,
              parts: [Part.new(plays: :noise, notes: drums), Part.new(plays: PART_WAVE, notes: pad)])
  end

  # A game that plays the song from its first pass, built with +options+ where given (a console).
  # It hands back the finished Builder.
  private def rattle_and_wave_builder(song = rattle_and_wave_song, options: nil)
    b = options ? VBlank::Builder.new(options: options) : VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [song]
      game_loop do
        music.play 0
        wait_vblank
      end
    end
    b.finalize_program
    b
  end

  # ...and its program.
  private def rattle_and_wave_game(song = rattle_and_wave_song) = rattle_and_wave_builder(song).program

  # A game that plays the same parts as a sound effect, once, over no song, from its first pass.
  private def rattle_and_wave_effect_game
    song = rattle_and_wave_song
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      effects = sound_effects :sfx, { hit: song }
      pass = var :pass, 0
      game_loop do
        pass += 1
        effects.play :hit if pass == 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end
end

# A NOTE'S OWN RATTLE AND ITS OWN WAVEFORM. What each note says is what the log says it played, on
# every run: the interpreter's, and every build checked against it.
class TestScoreNoteVoices < Minitest::Test
  include ScoreNoteVoicesGames

  private def played_log = game_player.run(rattle_and_wave_game, frames: 38).audio

  def test_each_drum_hit_rattles_as_its_note_says
    hits = played_log.select { |kind, hit| kind == :noise && hit }.map { |_, hit| hit[:metallic] }

    assert_equal [true, false, true, false], hits
  end

  def test_each_wave_note_plays_the_waveform_its_note_names
    shapes = played_log.filter_map { |kind, wave| wave[:shape] if kind == :wave && wave }

    assert_equal [:sine, STEPPED, PART_WAVE, :sine], shapes
  end

  # The song comes round after forty frames, and each note keeps its own setting the time after.
  def test_each_note_keeps_its_rattle_and_waveform_when_the_song_comes_round
    log = game_player.run(rattle_and_wave_game, frames: 60).audio
    hits = log.select { |kind, hit| kind == :noise && hit }.map { |_, hit| hit[:metallic] }
    shapes = log.filter_map { |kind, wave| wave[:shape] if kind == :wave && wave }

    assert_equal [true, false, true, false, true, false], hits.first(6)
    assert_equal [:sine, STEPPED, PART_WAVE, :sine, :sine, STEPPED], shapes.first(6)
  end

  def test_a_sound_effects_notes_rattle_and_change_wave_as_they_say
    log = game_player.run(rattle_and_wave_effect_game, frames: 40).audio

    assert_equal [true, false, true, false], log.select { |kind, hit| kind == :noise && hit }.map { |_, hit| hit[:metallic] }
    assert_equal [:sine, STEPPED, PART_WAVE, :sine], log.filter_map { |kind, wave| wave[:shape] if kind == :wave && wave }
  end

  private def build_error(*notes, plays:)
    assert_raises(ArgumentError) { rattle_and_wave_game(Score.new(parts: [Part.new(plays: plays, notes: notes)])) }.message
  end

  def test_a_rattle_off_the_noise_voice_is_a_friendly_error
    assert_match(/only a note on the noise voice/i, build_error(Note.new(at: 0, key: 60, metallic: true), plays: :wave))
  end

  def test_a_rattle_that_is_not_true_or_false_is_a_friendly_error
    assert_match(/true or false/, build_error(Note.new(at: 0, key: 60, metallic: :yes), plays: :noise))
  end

  def test_a_waveform_off_the_wave_voice_is_a_friendly_error
    assert_match(/only a note on the wave voice/i, build_error(Note.new(at: 0, key: 60, wave: :sine), plays: :noise))
  end

  def test_a_waveform_the_wave_voice_does_not_have_is_a_friendly_error
    assert_match(/a wave is a shape/i, build_error(Note.new(at: 0, key: 60, wave: :piano), plays: :wave))
    assert_match(/32 steps/, build_error(Note.new(at: 0, key: 60, wave: [1, 2, 3]), plays: :wave))
  end
end
