# frozen_string_literal: true

require "test_helper"
require "sound_effect_recording_tests"

# The games these tests play and what the run's player says about them, kept once for the same
# games on the Advance's cartridge
# (test/lowering/gba/vblank/dsl/test_sound_effects_on_the_advance_cartridge.rb). Those whose effects
# play a recording are shared with every console that mixes them (test/sound_effect_recording_tests.rb).
module SoundEffectsOnTheAdvanceGames
  include SoundEffectRecordingGames

  # What the interpreter says the wave voice was set to on each frame it was: the waveform of the
  # note, or :silent.
  private def wave_notes_by_frame(program, frames)
    i = game_player
    shapes = {}
    i.each_vblank do |frame|
      i.audio.each do |kind, settings|
        shapes[frame] = settings[:shape] if kind == :wave
        shapes[frame] = :silent if kind == :stop_wave
      end
      i.audio.clear
    end
    i.run(program, frames: frames)
    shapes
  end

  # [frames since the first setting that was not 0, setting] for each change in +settings+, one
  # setting a frame.
  private def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  # A waveform as the number wave RAM holds for it, reading its four words in order.
  private def waveform(shape)
    VBlank::IR::Backends::GameBoySound.wavetable_halfwords(shape).each_slice(2).each_with_index.sum do |(low, high), word|
      (low | (high << 16)) << (32 * word)
    end
  end

  # [frames since the wave voice first sounded, waveform] for each change, from the interpreter:
  # the waveform of the last note on the voice.
  private def interpreted_waveforms(program, frames:)
    shapes = wave_notes_by_frame(program, frames).reject { |_, shape| shape == :silent }
    loaded = nil
    changes((1..frames).filter_map { |frame| (loaded = shapes.fetch(frame, loaded)) && waveform(loaded) })
  end

  # The game's own `wave` on pass 5, over a song on the triangle, in a game whose one effect plays
  # the wave voice.
  private def games_own_wave_over_a_song
    triangle = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :triangle)
    hit = every_ten_ticks(:C5, plays: :sawtooth)
    game([hit], tune: triangle) { |_sfx, pass| wave :sine, :C5 if pass == 5 }
  end
end

# THE TESTS OF vblank/dsl/test_sound_effects.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file, and those
# whose effects play a recording are in test/sound_effect_recording_tests.rb.
#
# A SCORE PLAYED ONCE, AS A SOUND EFFECT, OVER THE SONG THAT IS PLAYING.
#
# A sword hit, a door, a chest opening: each is a short run of notes decoded from somewhere the
# same way a tune is, and each plays over the room's music without stopping it. When the effect
# and the song want the same voice, the one with the higher priority sounds on it.
class TestSoundEffectsOnTheAdvance < Minitest::Test
  include SoundEffectsOnTheAdvanceGames
  include SoundEffectRecordingTests

  # --- one effect on its own ---

  # The same Score named as a tune comes round, as any tune does: played as an effect it is walked
  # once as written, and played as a tune it is put right for coming round.
  def test_an_effect_named_as_a_tune_comes_round
    program = game([every_ten_ticks(:C5, :E5, length: 5)]) { |_sfx, pass| play_song :"sfx.0" if pass == 1 }
    starts = notes_by_frame(program, 80).values.flatten(1).count([:"sfx.0", NOTES[:C5]])

    assert_operator starts, :>=, 2, "the tune plays its first note again each time it comes round"
  end

  # --- on the wave voice ---

  # The game's own `wave` puts its waveform in wave RAM too, so the song's next note puts the
  # song's back — in a game whose effects play the wave voice, whether or not one is playing.
  # (The console doing the same is in the cartridge's tests.)
  def test_the_songs_waveform_comes_back_after_the_games_own_wave
    want = interpreted_waveforms(games_own_wave_over_a_song, frames: 30)

    assert_equal %i[triangle sine triangle].map { |shape| waveform(shape) }, want.map(&:last)
  end

  # --- on the mixer ---

  # How many voices sounded at once counts an effect's, with no song playing.
  def test_the_most_voices_at_once_counts_an_effects
    program = game([recorded_hit(68, parts: 3)]) { |sfx, pass| sfx.play 0 if pass == 3 }

    assert_equal 3, game_player.run(program, frames: 10).peak_voices
  end

  # The console held to every one of these, and to who gives way on a full mixer, the volume an
  # effect plays at and the pitch it reads its recording at, is in
  # test/lowering/gba/vblank/dsl/test_sound_effects_on_the_advance_cartridge.rb.
end
