# frozen_string_literal: true

# A SONG'S RECORDED NOTES WITH A SHAPE — climbing in, falling away after they end — and the voices a
# falling note holds, on every console whose build mixes recordings for its songs: the Advance's and
# the Super Nintendo's. Each console's folder has a test file that includes these:
#
#   test/console/gba/vblank/audio/test_note_envelope_on_the_advance.rb
#   test/console/snes/vblank/audio/test_note_envelope_on_the_super_nintendo.rb
#
# The games are kept apart (NoteEnvelopeVoiceGames) for the Advance's cartridge too
# (test/lowering/gba/vblank/audio/test_note_envelope_on_the_advance_cartridge.rb).
module NoteEnvelopeVoiceGames
  # A second of a sine, cut at a zero crossing so the recording itself has no step in it.
  CYCLE = 64
  RATE = 8000
  SINE = (0...CYCLE).map { |i| (Math.sin(i * 2 * Math::PI / CYCLE) * 100).round }.freeze
  RECORDING = (SINE * (RATE / CYCLE)).freeze

  # A tempo where one tick is one frame, so a note's length is said in frames.
  TEMPO = 150
  TICKS_PER_BEAT = 24

  # The recordings the console of the run sounds together.
  VOICES = VBlank::Console.described(VBlank::Testing.console).recordings_at_once
  SLOW_RELEASE = VBlank::Audio::Envelope.new(release: 250) # still sounding a good second after its note

  # A game with two recordings, a part that plays +notes+ shaped by SLOW_RELEASE, and — on pass
  # +burst+ — as many sounds of the game's own as there are voices, each a second long.
  private def voices_game(notes, burst: nil)
    tune = VBlank::Audio::Score.new(
      parts: [VBlank::Audio::Score::Part.new(plays: :low, envelope: SLOW_RELEASE, notes: notes)],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 200
    )
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :low, pcm: RECORDING, rate: RATE, note: :C4, holds_from: 0
      instrument :high, pcm: RECORDING, rate: RATE, note: :C4, holds_from: 0
      clips = (0...VOICES).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 1000, rate: 2000 }
      music = songs :music, [tune]
      music.play 0
      pass = 0
      game_loop do
        pass += 1
        clips.each(&:play) if burst && pass == burst
      end
    end
    b.finalize_program
    b.program
  end
end

# The tests of test_note_envelope.rb whose games play their notes from a recording and ask the run
# what is still sounding.
module NoteEnvelopeVoiceTests
  include NoteEnvelopeVoiceGames

  # Run a one-note song for +frames+ frames and hand back the run, so a test can ask what is still
  # sounding.
  private def interpret(envelope, frames:)
    tune = VBlank::Audio::Score.new(
      parts: [VBlank::Audio::Score::Part.new(plays: :tone, envelope: envelope,
                                       notes: [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 6)])],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 90
    )
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: RECORDING, rate: RATE, note: :C4
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end
    builder.finalize_program
    game_player.tap { |ruby| ruby.run(builder.program, frames: frames) }
  end

  def test_the_interpreter_lets_a_shaped_note_fall_away_and_stops_a_plain_one
    # The note ends on frame 6. A frame after that, a plain note is gone...
    assert_empty interpret(nil, frames: 10).active_samples,
                 "a note with no shape stops the moment it ends"

    # ...and a shaped one is still sounding, more quietly each frame.
    fading = interpret({ release: 0.5 }, frames: 10)

    assert_equal [:tone], fading.active_samples, "a shaped note goes on sounding as it falls"
    later = interpret({ release: 0.5 }, frames: 20)

    assert_operator later.level_of(:tone), :<, fading.level_of(:tone),
                    "...and it is quieter the longer it has been falling"
    assert_empty interpret({ release: 0.5 }, frames: 90).active_samples,
                 "and in the end it is over, and its voice goes back"
  end

  # A NOTE THE GAME PLAYS ITSELF starts its shape as it is played, the way a key struck on an
  # instrument sounds at once: as it is played its shape has moved on once, so the first frame it
  # is heard in is at that level, and it moves on once a frame from there. So an attack of 255 is
  # full in the very first frame, and a recording shorter than a frame is heard, not mixed at
  # nothing.
  CLIMBING_ENVELOPE = VBlank::Audio::Envelope.new(attack: 100, decay: 200, sustain: 120, release: 110)

  private def struck_game
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      keys = instrument :keys, pcm: RECORDING, rate: RATE, note: :C4, envelope: CLIMBING_ENVELOPE
      pass = 0
      game_loop do
        pass += 1
        keys.play(:E4) if pass == 3
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_shaped_instrument_the_game_plays_starts_its_shape_as_it_is_played
    program = struck_game
    first = (1..8).find { |frames| game_player.run(program, frames: frames).active_samples.include?(:keys) }
    refute_nil first, "the note never sounded"

    levels = (first..(first + 1)).map { |frames| game_player.run(program, frames: frames).level_of(:keys) }

    # An attack of 100 climbs 100 a frame: one step as it is played, then a second.
    assert_equal [100, 200], levels, "the shape moves on once as the note is played, and once a frame after"
  end

  # --- the voices a falling note holds, which every backend has to agree about ---

  # What the run has sounding +frames+ in, and what it could not play.
  private def run_voices(program, frames:)
    ruby = game_player.run(program, frames: frames)
    [ruby.active_samples, ruby.sound_drops]
  end

  def test_a_parts_next_note_leaves_the_last_falling_on_its_own_voice
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, instrument: :low),
             VBlank::Audio::Score::Note.new(at: 10, key: :C4, instrument: :high)]
    ruby, = run_voices(voices_game(notes), frames: 14)

    assert_equal %i[low high], ruby, "the first note falls away on its voice while the second sounds on another"
  end

  def test_a_game_sound_takes_a_falling_notes_voice_rather_than_being_dropped
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 4)]
    ruby = run_voices(voices_game(notes, burst: 10), frames: 14)

    clips = (0...VOICES).map { |n| :"s#{n}" }

    assert_equal [clips.last] + clips[0...-1], ruby.first,
                 "every voice is the game's: the last sound took the first voice, which the falling note gave up"
    assert_equal 0, ruby.last.dropped
  end
end
