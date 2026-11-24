# frozen_string_literal: true

require "test_helper"

# A sound effect whose ticks are a timer's. A cartridge's own sound engine often counts an effect on
# a timer of its sound chip's, not in frames: at 50 ticks a second a tick is a frame and a fifth, so
# its notes fall part way through frames and the frames between them are not all alike.
# `on_timer: true` on the effect's Score plays it that way.
#
# The answer key here is the timer as every player keeps it (IR::Tunes.effect_clock_step): from
# power-on each frame adds the step, the part of a tick a frame lasts on the console played, to a
# count of 16 bits, and the frame whose addition takes the count past the top holds a tick. The step
# is rounded down, so over a long run the ticks fall a frame later than exact fractions put them; the
# runs here are long enough to cross frames where the two disagree. The effect starts on the first
# tick after it is asked for, and the note at tick t sounds on the frame that holds the effect's t-th
# tick after that one.
class TestSoundEffectOnTimer < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  RATE = 50 # ticks a second: a tempo of 125 at 24 ticks a beat
  NOTE_TICKS = [0, 3, 5, 8, 10].freeze # waits of 3 and 2 ticks, as a driver's script holds them
  PITCHES = [880, 659, 880, 659, 880].freeze # A5 and E5 in turn
  LENGTH = 20 # ticks
  FRAMES = 1200 # past the frames where exact fractions and the rounded step part
  ASKED_EVERY = 40 # passes, so each effect has ended before the next is asked for

  private def effect(on_timer: true, tempo: 125, ticks_per_beat: 24)
    notes = NOTE_TICKS.each_with_index.map { |at, n| Note.new(at: at, key: n.even? ? :A5 : :E5) }
    Score.new(tempo: tempo, ticks_per_beat: ticks_per_beat, length: LENGTH, plays_once: true, on_timer: on_timer,
              parts: [Part.new(notes: notes)])
  end

  # The game: the effect asked for in each pass whose count is +asked_on+ past a whole number of
  # ASKED_EVERY (the first pass's count is 0), and the frames the effect started on and its notes
  # sounded on, as [frame, pitch] read from the log.
  private def played(score, asked_on:, frames: FRAMES)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: score }
      count = var(:count, 0)
      game_loop do
        list.play :chime if count % ASKED_EVERY == asked_on
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
        notes << [frame, entry[2].round] if entry.first == :note && entry[1] == :"sfx.chime" && entry[2].positive?
      end
      logged = player.audio.size
    end
    player.run(b.program, frames: frames)
    [b.program, started, notes]
  end

  # The console this run plays the game as, whose frames the timer is counted against: the game
  # names none, so each run plays it as its own.
  private def console_played(program)
    VBlank::Testing.console ? VBlank::Console.described(VBlank::Testing.console) : program.described_console
  end

  # The frames from power-on, counted from 1, that hold a tick of the timer on +console+.
  private def ticking_frames(program, console, through:)
    step = VBlank::IR::Tunes.effect_clock_step(program, console)
    count = 0
    (1..through).select do
      count += step
      ticked = count >= VBlank::IR::Tunes::CLOCK_MODULUS
      count %= VBlank::IR::Tunes::CLOCK_MODULUS
      ticked
    end
  end

  # The first frame the player can start an effect asked for in the pass whose count is +count+: the
  # frame an effect counted in frames starts on (test_an_effect_not_on_the_timer_counts_frames), the
  # game having set up on the first.
  private def first_frame_after(count) = count + 2

  # The frames each effect asked for starts on, and the [frame, pitch] of each of its notes, as far as
  # +frames+.
  private def expected(program, asked_on:, frames: FRAMES)
    ticks = ticking_frames(program, console_played(program), through: frames)
    asks = (asked_on...frames).step(ASKED_EVERY)
    runs = asks.filter_map do |count|
      own = ticks.select { |n| n >= first_frame_after(count) }
      [own.first, NOTE_TICKS.zip(PITCHES).filter_map { |tick, pitch| [own[tick], pitch] if own[tick] }] if own.first
    end
    [runs.map(&:first), runs.flat_map(&:last)]
  end

  def test_the_notes_sound_on_the_frames_their_ticks_fall_in
    program, started, notes = played(effect, asked_on: 0)
    starts, struck = expected(program, asked_on: 0)

    assert_operator starts.size, :>=, FRAMES / ASKED_EVERY - 1
    assert_equal starts, started
    assert_equal struck, notes
  end

  def test_an_effect_asked_for_between_ticks_starts_on_the_next
    program, started, notes = played(effect, asked_on: 7)
    starts, struck = expected(program, asked_on: 7)

    assert_equal starts, started
    assert_equal struck, notes
  end

  def test_an_effect_not_on_the_timer_counts_frames
    _, started, notes = played(effect(on_timer: false), asked_on: 0, frames: 30)

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
    assert_match(/60 times a second.*50 times a second/, error.message)
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
