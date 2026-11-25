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

  # The frames from power-on the effect is asked for on, and the game's own sound played on: counted
  # from power-on rather than in passes, since a console that takes longer to set up one build (a
  # longer sound program to send) would otherwise play both a frame later in that build.
  STARTED_ON = 10
  SOUNDED_ON = 16
  FRAMES = 24
  RATE = 240 # ticks a second: four a frame, so the frame the game's sound is played in has one after it
  TICKS = 120
  SHORT_RUN = 40 # samples on one side of nought: longer than the game's sound's half wave, shorter than the effect's
  TAIL = 60 # the frame's last samples, where the game's sound is still heard: longer than SHORT_RUN

  Heard = Data.define(:onset, :held_to_frame_end)

  # Where the game's own +sound+ (:beep or :wave) is first heard, in frames from power-on, and whether
  # it is still heard at the end of that frame. +on_timer+ false plays the effect at the frame's start.
  def game_sound_heard(console:, on_timer:, sound:, rate: RATE)
    reader = VBlank::Diagnostics::Verifier.new(game_sound_cartridge(console, on_timer, sound, rate), frames: 0)
    frames = Array.new(FRAMES) do
      reader.step(1)
      reader.last_frame_samples.each_slice(2).map(&:first)
    end
    game_sound_onset(frames)
  ensure
    reader&.close
  end

  private def game_sound_cartridge(console, on_timer, sound, rate = RATE)
    VBlank.build("STRIKES", console: console, out: nil, err: nil, &game_sound_code(on_timer, sound, rate))
  end

  # ...as a program for +console+, struck on the timer, for a checked run.
  def game_sound_program(console, sound, rate = RATE)
    builder = VBlank::Builder.new
    builder.instance_eval(&game_sound_code(true, sound, rate))
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = console }
  end

  private def game_sound_code(on_timer, sound, rate)
    low = (0...TICKS).map { |n| Note.new(at: n, key: :C3, length: 1, volume: 15) }
    quiet = [Note.new(at: 0, key: :C3, length: TICKS, volume: 0)]
    parts = sound == :wave ? [Part.new(plays: :wave, notes: low)] : [Part.new(notes: quiet), Part.new(notes: low)]
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: TICKS, plays_once: true, on_timer: on_timer, parts: parts)
    proc do
      enable_sound
      define_sound :ping, frequency: 1500, duty: :half, decay: :none, volume: 15
      sfx = sound_effects :sfx, { chime: effect }
      started = var :started, 0
      sounded = var :sounded, 0
      game_loop do
        if started == 0 && frames_since_power_on >= STARTED_ON
          started = 1
          sfx.play :chime
        end
        if sounded == 0 && frames_since_power_on >= SOUNDED_ON
          sounded = 1
          wave(:square, 1500) if sound == :wave
          beep(:ping) if sound == :beep
        end
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
  # and still heard at that frame's end, the effect's timer ticking +rate+ times a second.
  def assert_game_sound_heard_over_effect(console, sound, near:, rate: RATE)
    at_start = game_sound_heard(console: console, on_timer: false, sound: sound, rate: rate)
    struck = game_sound_heard(console: console, on_timer: true, sound: sound, rate: rate)

    refute_nil at_start.onset, "the game's #{sound} heard with the effect at the frame's start"
    refute_nil struck.onset, "the game's #{sound} heard with the effect struck inside the frame"
    assert_in_delta at_start.onset, struck.onset, near,
                    "the game's #{sound} first heard at frame #{struck.onset.to_f.round(3)}, at the frame's start #{at_start.onset.to_f.round(3)}"
    assert struck.held_to_frame_end, "the game's #{sound} cut off before its frame's end"
  end

  # ### The tune taking back a voice the effect lets go
  #
  # An effect ranked above the tune holds the tune's second square voice with a high note for
  # RELEASED_AFTER ticks and ends; the tune plays a low note on that voice every frame. On the frame the
  # effect lets the voice go, the tune's note takes it back (Reference::Player), so the low note is heard
  # on without a break. Written ahead of the effect's listed release, the tune's note is silenced at the
  # release's line until its next note, a frame later: a run of samples on one side of nought far longer
  # than the low note's half wave.
  RELEASED_AFTER = 12
  RELEASE_RATE = 50
  RELEASE_ASKED_ON = 20
  RELEASE_FRAMES = 50
  RELEASE_HEARD_FROM = 24

  # The longest run of the left speaker's samples on one side of nought, from RELEASE_HEARD_FROM on,
  # with the effect on the timer or (+on_timer+ false) at the frame's start.
  def longest_run_after_release(console:, on_timer:)
    reader = VBlank::Diagnostics::Verifier.new(release_cartridge(console, on_timer), frames: 0)
    samples = []
    RELEASE_FRAMES.times do |frame|
      reader.step(1)
      samples.concat(reader.last_frame_samples.each_slice(2).map(&:first)) if frame >= RELEASE_HEARD_FROM
    end
    samples.chunk_while { |was, now| (was >= 0) == (now >= 0) }.map(&:size).max
  ensure
    reader&.close
  end

  private def release_cartridge(console, on_timer)
    effect = Score.new(tempo: RELEASE_RATE, ticks_per_beat: 60, length: RELEASED_AFTER, plays_once: true, on_timer: on_timer,
                       priority: 100, parts: [Part.new(notes: [Note.new(at: 0, key: :C3, length: RELEASED_AFTER, volume: 0)]),
                                              Part.new(notes: [Note.new(at: 0, key: :C6, length: RELEASED_AFTER, volume: 15)])])
    tune = Score.new(tempo: 150, ticks_per_beat: 24, length: 240, priority: 0,
                     parts: [Part.new(notes: [Note.new(at: 0, key: :C3, length: 240, volume: 0)]),
                             Part.new(notes: (0...240).map { |n| Note.new(at: n, key: :C3, length: 1, volume: 15) })])
    VBlank.build("RELEASE", console: console, out: nil, err: nil) do
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, { chime: effect }
      started = var :started, 0
      game_loop do
        music.play 0
        if started == 0 && frames_since_power_on >= RELEASE_ASKED_ON
          started = 1
          sfx.play :chime
        end
      end
    end
  end

  # No run on one side of nought after the effect lets go longer than a fifth more than the longest with
  # the effect at the frame's start.
  def assert_tune_heard_after_effect_lets_go(console)
    at_start = longest_run_after_release(console: console, on_timer: false)
    struck = longest_run_after_release(console: console, on_timer: true)

    assert_operator struck, :<=, at_start * 6 / 5, "the tune's note silenced after the effect let its voice go"
  end
end
