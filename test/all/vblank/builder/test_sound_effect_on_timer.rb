# frozen_string_literal: true

require "test_helper"

# A sound effect whose ticks are a timer's. A cartridge's own sound engine often counts an effect on
# a timer of its sound chip's, not in frames: at 50 ticks a second a tick is a frame and a fifth, so
# its notes fall part way through frames and the frames between them are not all alike.
# `on_timer: true` on the effect's Score plays it that way.
#
# The answer key here is the timer itself, worked out in exact fractions: a timer of RATE ticks a
# second, running from power-on, ticks at k / RATE seconds, and the frame that holds a tick is the
# one whose end it falls before. The effect starts on the first tick after it is asked for, and the
# note at tick t sounds on the frame that holds the effect's t-th tick after that one.
class TestSoundEffectOnTimer < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  RATE = 50 # ticks a second: a tempo of 125 at 24 ticks a beat
  NOTE_TICKS = [0, 3, 5, 8, 10].freeze # waits of 3 and 2 ticks, as a driver's script holds them
  LENGTH = 20 # ticks

  private def effect(on_timer: true, tempo: 125, ticks_per_beat: 24)
    notes = NOTE_TICKS.each_with_index.map { |at, n| Note.new(at: at, key: n.even? ? :A5 : :E5) }
    Score.new(tempo: tempo, ticks_per_beat: ticks_per_beat, length: LENGTH, plays_once: true, on_timer: on_timer,
              parts: [Part.new(notes: notes)])
  end

  # The game: the effect asked for in the pass whose count is +asked_on+ (its first is 0), and the
  # frames the effect started on and its notes sounded on, as [frame, pitch] read from the log.
  private def played(score, asked_on:, frames: 60)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: score }
      count = var(:count, 0)
      game_loop do
        list.play :chime if count == asked_on
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    player = game_player
    started = []
    notes = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each do |entry|
        started << frame if entry == [:sound_effect, :"sfx.chime"]
        notes << [frame, entry[2]] if entry.first == :note && entry[1] == :"sfx.chime" && entry[2].positive?
      end
      logged = player.audio.size
    end
    player.run(b.program, frames: frames)
    [b.program, started, notes]
  end

  # The frames from power-on that hold a tick of the timer, on +console+: frame n (counted from 1) ends
  # n frames' time after power-on, and holds tick k when k / RATE is in it.
  private def ticking_frames(console, through:)
    per_frame = RATE * console.frame_seconds # ticks a frame, less than one
    (1..through).select { |n| (n * per_frame).floor > ((n - 1) * per_frame).floor }
  end

  # The first frame the player can start an effect asked for on the game's count +asked_on+: the frame
  # an effect counted in frames starts on (test_an_effect_not_on_the_timer_counts_frames), the game
  # having set up on the first.
  private def first_frame_after(asked_on) = asked_on + 2

  # The console this run plays the game as, whose frames the timer is counted against: the game
  # names none, so each run plays it as its own.
  private def console_played(program)
    VBlank::Testing.console ? VBlank::Console.described(VBlank::Testing.console) : program.described_console
  end

  private def expected(program, asked_on:, frames:)
    ticks = ticking_frames(console_played(program), through: frames).select { |n| n >= first_frame_after(asked_on) }
    pitches = NOTE_TICKS.each_with_index.map { |_, n| n.even? ? 880 : 659 }
    [ticks.first, NOTE_TICKS.zip(pitches).map { |tick, pitch| [ticks[tick], pitch] }]
  end

  def test_the_notes_sound_on_the_frames_their_ticks_fall_in
    program, started, notes = played(effect, asked_on: 0)
    start, struck = expected(program, asked_on: 0, frames: 60)

    assert_equal [start], started
    assert_equal struck, notes.map { |frame, hz| [frame, hz.round] }
  end

  def test_an_effect_asked_for_between_ticks_starts_on_the_next
    program, started, notes = played(effect, asked_on: 7)
    start, struck = expected(program, asked_on: 7, frames: 60)

    assert_equal [start], started
    assert_equal struck, notes.map { |frame, hz| [frame, hz.round] }
  end

  def test_an_effect_not_on_the_timer_counts_frames
    _, started, notes = played(effect(on_timer: false), asked_on: 0)

    # Ticks of a fiftieth of a second rounded to the nearest sixtieth, from the frame the ask is taken up.
    assert_equal [2], started
    assert_equal [2, 6, 8, 12, 14], notes.map(&:first)
  end

  def test_a_song_cannot_be_on_the_timer
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { songs :music, [Score.new(on_timer: true, parts: [Part.new(notes: [])])] } }

    assert_match(/Only a sound effect/, error.message)
  end

  def test_every_effect_is_on_the_timer_or_none_is
    plain = effect(on_timer: false)
    timed = effect
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { sound_effects :sfx, { a: plain, b: timed } } }

    assert_match(/all on the timer, or none is/, error.message)
  end

  def test_the_timer_ticks_at_one_rate
    timed = effect
    faster = effect(tempo: 150)
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        sound_effects :sfx, { a: timed }
        sound_effects :more, { b: faster }
      end
    end

    assert_match(/ticks at one rate/, error.message)
  end

  def test_a_tempo_that_changes_cannot_be_on_the_timer
    error = assert_raises(ArgumentError) { effect(tempo: [[0, 125], [5, 150]]).to_song }

    assert_match(/tempo that changes/, error.message)
  end

  def test_an_effect_on_the_timer_cannot_start_this_frame
    score = effect
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { sound_effects(:sfx, { a: score }).play(:a, this_frame: true) } }

    assert_match(/next tick of the timer/, error.message)
  end
end
