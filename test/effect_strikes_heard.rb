# frozen_string_literal: true

# The game's own sound on a voice a sound effect on a timer holds, played on a console that strikes the
# effect's notes inside the frame (IR::Tunes, "The game's own sound against a listed strike"). The
# effect plays a low note on every tick, and the game plays its own high sound once, on a pass part
# way through: written after the frame's effects are played and before their strike. Its sound is
# made at once and the strike listed for its voice dropped, so it is heard from where the game plays
# it to the frame's end, as where the effect plays at the frame's start. Folded into the listed strike
# it would start late, at the strike's line; left beside it, it would be cut off there.
#
# Read from the emulator's left speaker: the game's sound is a short wave and the effect's note a long
# one, so where the runs of samples on one side of nought are short, the game's sound is heard.
module EffectStrikesHeard
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  STARTED_ON = 10 # the pass the effect is asked for on
  SOUNDED_ON = 16 # the pass the game's own sound is played on
  FRAMES = 24
  RATE = 240 # ticks a second: four a frame, so the frame the game's sound is played in has one after it
  TICKS = 120
  SHORT_RUN = 40 # samples on one side of nought: longer than the game's sound's half wave, shorter than the effect's
  TAIL = 60 # the frame's last samples, where the game's sound is still heard: longer than SHORT_RUN

  Heard = Data.define(:onset, :held_to_frame_end)

  # Where the game's own +sound+ (:beep or :wave) is first heard, in frames from power-on, and whether
  # it is still heard at the end of that frame. +on_timer+ false plays the effect at the frame's start.
  def game_sound_heard(console:, on_timer:, sound:)
    reader = VBlank::Diagnostics::Verifier.new(game_sound_cartridge(console, on_timer, sound), frames: 0)
    frames = Array.new(FRAMES) do
      reader.step(1)
      reader.last_frame_samples.each_slice(2).map(&:first)
    end
    game_sound_onset(frames)
  ensure
    reader&.close
  end

  private def game_sound_cartridge(console, on_timer, sound)
    low = (0...TICKS).map { |n| Note.new(at: n, key: :C3, length: 1, volume: 15) }
    quiet = [Note.new(at: 0, key: :C3, length: TICKS, volume: 0)]
    parts = sound == :wave ? [Part.new(plays: :wave, notes: low)] : [Part.new(notes: quiet), Part.new(notes: low)]
    effect = Score.new(tempo: RATE, ticks_per_beat: 60, length: TICKS, plays_once: true, on_timer: on_timer, parts: parts)
    VBlank.build("STRIKES", console: console, out: nil, err: nil) do
      enable_sound
      define_sound :ping, frequency: 1500, duty: :half, decay: :none, volume: 15
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == STARTED_ON
        wave(:square, 1500) if sound == :wave && pass == SOUNDED_ON
        beep(:ping) if sound == :beep && pass == SOUNDED_ON
      end
    end
  end

  # The first of HEARD_RUNS short runs in a row, from the frame before the game's sound's pass on.
  HEARD_RUNS = 6

  private def game_sound_onset(frames)
    frames.each_with_index.drop(SOUNDED_ON - 1).each do |samples, frame|
      runs = samples.chunk_while { |was, now| (was >= 0) == (now >= 0) }.map(&:size)
      starts = runs.each_with_index.map { |_, n| runs.take(n).sum }
      first = (1...runs.size).find { |n| runs[n, HEARD_RUNS].size == HEARD_RUNS && runs[n, HEARD_RUNS].all? { |size| size < SHORT_RUN } }
      next unless first

      tail = samples.last(TAIL).chunk_while { |was, now| (was >= 0) == (now >= 0) }
      return Heard.new(onset: frame + Rational(starts[first], samples.size), held_to_frame_end: tail.all? { |run| run.size < SHORT_RUN })
    end
    Heard.new(onset: nil, held_to_frame_end: false)
  end

  # The game's +sound+ heard within +near+ frames of where it is with the effect at the frame's start,
  # and still heard at that frame's end.
  def assert_game_sound_heard_over_effect(console, sound, near:)
    at_start = game_sound_heard(console: console, on_timer: false, sound: sound)
    struck = game_sound_heard(console: console, on_timer: true, sound: sound)

    refute_nil at_start.onset, "the game's #{sound} heard with the effect at the frame's start"
    refute_nil struck.onset, "the game's #{sound} heard with the effect struck inside the frame"
    assert_in_delta at_start.onset, struck.onset, near,
                    "the game's #{sound} first heard at frame #{struck.onset.to_f.round(3)}, at the frame's start #{at_start.onset.to_f.round(3)}"
    assert struck.held_to_frame_end, "the game's #{sound} cut off before its frame's end"
  end
end
