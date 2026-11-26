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
# runs here are long enough to cross frames where the two disagree. The effect starts at once on the
# frame the player takes the ask up, as a sound driver strikes an effect's first note when it is
# told, and the note at tick t sounds on the frame that holds the timer's t-th tick after that frame:
# a tick falling in the frame it starts on is too close to its start to move it on, so its first note
# always lasts past the frame, as a driver's own does.
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

  private def effect(on_timer: true, tempo: 125, ticks_per_beat: 24, interrupts: nil, **counts)
    notes = NOTE_TICKS.each_with_index.map { |at, n| Note.new(at: at, key: n.even? ? :A5 : :E5) }
    Score.new(tempo: tempo, ticks_per_beat: ticks_per_beat, length: LENGTH, plays_once: true, on_timer: on_timer,
              interrupts_per_second: interrupts, **counts, parts: [Part.new(notes: notes)])
  end

  # The game: the effect asked for in each pass whose count is +asked_on+ past a whole number of
  # ASKED_EVERY (the first pass's count is 0), and the frames the effect started on and its notes
  # sounded on, as [frame, pitch] read from the log.
  # With +songs_on+, a Hash of a pass's count to a tune's place in +tune_list+, that tune is asked for on that
  # pass, and on each count in +stops_on+ the game stops the music.
  private def played(score, asked_on:, frames: FRAMES, songs_on: {}, tune_list: TUNES, stops_on: [], player: game_player)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: score }
      list_of_tunes = songs(:music, tune_list) unless songs_on.empty?
      count = var(:count, 0)
      game_loop do
        songs_on.each { |on, tune| list_of_tunes.play tune if count == on }
        stops_on.each { |on| stop_music if count == on }
        list.play :chime if count % ASKED_EVERY == asked_on
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
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
    # The interpreter by name plays the game as the console of the run, as the run's own player does.
    program = player.is_a?(Reference) && VBlank::Testing.console ? b.program.copy.tap { |p| p.console = VBlank::Testing.console } : b.program
    player.run(program, frames: frames)
    [b.program, started, notes]
  end

  # The console this run plays the game as, whose frames the timer is counted against: the game
  # names none, so each run plays it as its own.
  private def console_played(program)
    VBlank::Testing.console ? VBlank::Console.described(VBlank::Testing.console) : program.described_console
  end

  # The frame from power-on, counted from 1, of each tick of the timer on +console+: a frame that
  # holds several ticks is named once for each.
  private def ticking_frames(program, console, through:, start: 0)
    step = VBlank::IR::Tunes.effect_clock_step(program, console)
    count = start
    (1..through).flat_map do |frame|
      count += step
      ticks = count / VBlank::IR::Tunes::CLOCK_MODULUS
      count %= VBlank::IR::Tunes::CLOCK_MODULUS
      [frame] * ticks
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
      start = first_frame_after(count)
      own = [start] + ticks.select { |n| n > start }
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

  # Asked for on a pass whose frame holds no tick, it starts there all the same, and its next note
  # waits for the timer's next tick.
  def test_an_effect_asked_for_between_ticks_starts_on_the_frame_it_is_taken_up
    program, started, notes = played(effect, asked_on: 7)
    starts, struck = expected(program, asked_on: 7)

    assert_equal starts, started
    assert_equal struck, notes
  end

  # Faster than the frames: 90 ticks a second is a frame of one tick, then one of two; 120 is two
  # a frame, with a frame of three now and then on a console a little slower than sixty; 240 is four
  # or five. Every tick's note sounds on its own frame, two or more on one frame in order.
  def test_a_timer_faster_than_the_frames_plays_every_tick
    { 90 => [225, 24], 120 => [150, 48], 240 => [150, 96] }.each do |rate, (tempo, ticks_per_beat)|
      program, started, notes = played(effect(tempo: tempo, ticks_per_beat: ticks_per_beat), asked_on: 3)
      starts, struck = expected(program, asked_on: 3)

      assert_operator starts.size, :>=, FRAMES / ASKED_EVERY - 1, "#{rate} a second"
      assert_equal starts, started, "#{rate} a second"
      assert_equal struck, notes, "#{rate} a second"
    end
  end

  # An effect ranked below the tune that is playing starts on the frame it is taken up, whether or
  # not that frame has a tick, as one above the tune does. Asked for every seventh pass, so the asks
  # fall on frames of every kind.
  BELOW_ASKED_EVERY = 7
  BELOW_FRAMES = 90

  def test_an_effect_below_the_tune_starts_on_the_frame_it_is_taken_up
    tune = Score.new(tempo: 150, priority: 200, parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 8)])])
    quiet = Score.new(tempo: 125, ticks_per_beat: 24, length: LENGTH, plays_once: true, on_timer: true, priority: 10,
                      parts: [Part.new(notes: [Note.new(at: 0, key: :E5), Note.new(at: 3, key: :A5)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [tune]
      list = sound_effects :sfx, { chime: quiet }
      count = var(:count, 0)
      game_loop do
        music.play 0
        list.play :chime if count % BELOW_ASKED_EVERY == 3
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    player = game_player
    started = []
    logged = 0
    player.each_vblank do |frame|
      started << frame if player.audio.drop(logged).include?([:sound_effect, :"sfx.chime"])
      logged = player.audio.size
    end
    player.run(b.program, frames: BELOW_FRAMES)

    asks = (3...BELOW_FRAMES).step(BELOW_ASKED_EVERY).map { |count| first_frame_after(count) }.select { |frame| frame <= BELOW_FRAMES }
    assert_equal asks, started
  end

  # A first note one tick long, then a second, asked for every few passes while the last still
  # sounds: each ask starts it again, and its first note is the only one on the frame it starts, so it
  # is heard past that frame, whatever the timer does in it.
  STEP_ASKED_EVERY = 13
  STEP_FRAMES = 120

  def test_a_one_tick_first_note_is_alone_on_its_frame_on_every_ask
    step = Score.new(tempo: 125, ticks_per_beat: 24, length: 14, plays_once: true, on_timer: true,
                     parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 1), Note.new(at: 1, key: :B5, length: 2)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { step: step }
      count = var(:count, 0)
      game_loop do
        list.play :step if count % STEP_ASKED_EVERY == 3
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    player = game_player
    by_frame = Hash.new { |hash, frame| hash[frame] = [] }
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| by_frame[frame] << entry[2] if entry.first == :note && entry[1] == :"sfx.step" }
      logged = player.audio.size
    end
    player.run(b.program, frames: STEP_FRAMES)

    first = 659 # E5, as the log writes it
    starts = by_frame.select { |_, pitches| pitches.include?(first) }
    asks = (0...STEP_FRAMES).count { |count| count % STEP_ASKED_EVERY == 3 && first_frame_after(count) <= STEP_FRAMES }
    assert_equal asks, starts.size, by_frame.inspect
    starts.each { |frame, pitches| assert_equal [first], pitches, "the first note alone on frame #{frame}" }
  end

  # On a driver's own interrupt (`interrupts_per_second:`), as the answer key keeps it
  # (IR::Tunes.effect_tempo_step): each frame adds the interrupt's step to a count of 16 bits and holds
  # an interrupt each time it comes round; each interrupt adds the tempo's step to a count of its own
  # and holds a tick where that comes round. An effect starts on the frame it is taken up, and its
  # note at tick t sounds on the frame of the t-th tick after its start, a tick on the first interrupt
  # of that frame not counting, since it started on that interrupt. 8000 / 0x60, a timer's divider
  # worked out, is 83 and a third interrupts a second: one or two a frame.
  INTERRUPTS = Rational(8000, 0x60)

  # Each tick of the timer from power-on, as [frame, which interrupt of that frame], counted from 1, as
  # a driver counts its tempo on its interrupt. Each interrupt adds the tempo's step: the effects' own,
  # or with +tunes+ (a Hash of a frame to the step of the tune taken up on it, nought for none) the step
  # of the tune playing. With +reset+, [frame, share in 65536ths], the count is set to the share on that
  # frame and counted at it until it next comes round, the tempo again after.
  private def ticks_on_interrupts(program, console, through:, tunes: nil, reset: nil)
    step = VBlank::IR::Tunes.effect_clock_step(program, console)
    tempo = tunes ? 0 : VBlank::IR::Tunes.effect_tempo_step(program)
    interrupt_count = 0
    count = 0
    until_tick = 0
    (1..through).flat_map do |frame|
      tempo = tunes.fetch(frame) if tunes&.key?(frame)
      count = until_tick = reset.last if reset && frame == reset.first
      interrupt_count += step
      interrupts = interrupt_count / VBlank::IR::Tunes::CLOCK_MODULUS
      interrupt_count %= VBlank::IR::Tunes::CLOCK_MODULUS
      (0...interrupts).filter_map do |index|
        count += until_tick.nonzero? || tempo
        ticked = count >= VBlank::IR::Tunes::CLOCK_MODULUS
        count %= VBlank::IR::Tunes::CLOCK_MODULUS
        until_tick = 0 if ticked
        [frame, index] if ticked
      end
    end
  end

  def test_on_a_drivers_interrupt_the_notes_sound_on_the_frames_of_its_ticks
    [0, 7, 13, 22].each do |asked_on|
      program, started, notes = played(effect(interrupts: INTERRUPTS), asked_on: asked_on)
      ticks = ticks_on_interrupts(program, console_played(program), through: FRAMES)
      runs = (asked_on...FRAMES).step(ASKED_EVERY).map do |count|
        start = first_frame_after(count)
        own = [start] + ticks.reject { |frame, index| frame < start || (frame == start && index.zero?) }.map(&:first)
        [start, NOTE_TICKS.zip(PITCHES).filter_map { |tick, pitch| [own[tick], pitch] if own[tick] }]
      end

      assert_equal runs.map(&:first), started, "asked on #{asked_on}"
      assert_equal runs.flat_map(&:last), notes, "asked on #{asked_on}"
    end
  end

  # Two tunes on the noise voice, which the effect does not play: 60 ticks a second and 30.
  TUNES = [Score.new(tempo: 150, length: 96, parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: :C4)])]),
           Score.new(tempo: 75, length: 96, parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: :C4)])])].freeze
  SONG_ON = 30
  SECOND_SONG_ON = 515

  # The notes of the effect played as +score+, each [frame, pitch], from the interpreter by name, which
  # is held frame for frame to the beats +tunes+ and +reset+ give (#ticks_on_interrupts); and played on
  # the run's own player too, which every run holds to the interpreter pass for pass. A cartridge whose
  # pass overruns a frame is a frame behind the interpreter's count of frames from there, so its own
  # frames are not the answer.
  private def notes_on_beats(score, tunes: nil, reset: nil, songs_on: {}, asked_on: 7, **game)
    played(score, asked_on: asked_on, songs_on: songs_on, **game)
    program, _, notes = played(score, asked_on: asked_on, songs_on: songs_on, player: Reference.new, **game)
    ticks = ticks_on_interrupts(program, console_played(program), through: FRAMES, tunes: tunes, reset: reset)
    expected = (asked_on...FRAMES).step(ASKED_EVERY).flat_map do |count|
      first = first_frame_after(count)
      own = [first] + ticks.reject { |frame, index| frame < first || (frame == first && index.zero?) }.map(&:first)
      NOTE_TICKS.zip(PITCHES).filter_map { |tick, pitch| [own[tick], pitch] if own[tick] }
    end
    assert_equal expected, notes
    expected
  end

  # The step a tune counts the effects at, its ticks a second over the interrupt's.
  private def tune_step(tune) = (tune.tick_rate / INTERRUPTS * VBlank::IR::Tunes::CLOCK_MODULUS).floor

  # A song's start sets the count to 255/256 of a tick, as many a driver does, and counts it at that until
  # it comes round, so the song's first tick is at once; the beats move off those a free count gives
  # (Audio::Score's +tick_count_at_song_start+).
  def test_a_songs_start_sets_the_tempo_count_on_a_drivers_interrupt
    songs_on = { SONG_ON => 0 }
    reset = notes_on_beats(effect(interrupts: INTERRUPTS, tick_count_at_song_start: 255/256r), songs_on: songs_on,
                           reset: [first_frame_after(SONG_ON), 0xFF00])
    unset = notes_on_beats(effect(interrupts: INTERRUPTS), songs_on: songs_on)

    refute_equal unset, reset, "the song's start moves the beats"
  end

  # On the tune's tempo the effects count at the tempo of the song playing, and not at all before one
  # plays: the effect asked for first sounds its first note and waits there (Audio::Score's +on_tune_tempo+).
  def test_on_the_tunes_tempo_the_effects_count_at_the_song_playing
    songs_on = { SONG_ON => 0, SECOND_SONG_ON => 1 }
    tunes = { first_frame_after(SONG_ON) => tune_step(TUNES[0]), first_frame_after(SECOND_SONG_ON) => tune_step(TUNES[1]) }
    notes = notes_on_beats(effect(interrupts: INTERRUPTS, on_tune_tempo: true), songs_on: songs_on,
                           tunes: tunes, reset: nil)

    assert_equal [9, 880], notes.first, "the first note at once, before any song"
    refute_includes notes.map(&:first), 12, "and nothing more until the song starts"
  end

  # A tune that plays once: its end leaves no song playing.
  ONCE = [TUNES[0].with(plays_once: true)].freeze
  STILL_ASKED_ON = 7 # each effect asked for 40 passes apart from here

  # The notes that sound on frames from +frame+ on, each [frame, pitch].
  private def notes_from(notes, frame) = notes.select { |at, _| at >= frame }

  # The first note, [frame, pitch], of each effect taken up from +frame+ on.
  private def first_notes_from(frame)
    starts = (STILL_ASKED_ON...FRAMES).step(ASKED_EVERY).map { |count| first_frame_after(count) }
    starts.select { |at| at >= frame }.map { |at| [at, PITCHES.first] }
  end

  # On the tune's tempo, a tune that plays once and ends leaves no song playing: from the frame after its
  # last, the effects' count adds nothing, so each effect taken up then sounds its first note and holds
  # still there (Reference::Player#switch_to_wanted_song drops the tune that ended).
  def test_on_the_tunes_tempo_the_effects_hold_still_once_a_tune_that_plays_once_ends
    started = first_frame_after(SONG_ON)
    ended = started + ONCE.first.to_song[:total_frames]
    notes = notes_on_beats(effect(interrupts: INTERRUPTS, on_tune_tempo: true), songs_on: { SONG_ON => 0 }, tune_list: ONCE,
                           tunes: { started => tune_step(ONCE.first), ended => 0 }, asked_on: STILL_ASKED_ON)
    playing = notes.select { |at, _| at >= started && at < ended }

    assert_operator playing.size, :>, first_notes_from(started).count { |at, _| at < ended }, "the effects move on while it plays"
    assert_equal first_notes_from(ended), notes_from(notes, ended), "and only their first notes sound once it has ended"
  end

  # ...and a stop leaves none either: the effect sounding as the music stops holds still where it is.
  def test_on_the_tunes_tempo_the_effects_hold_still_once_the_music_stops
    started = first_frame_after(SONG_ON)
    stopped = first_frame_after(92)
    sounding = first_frame_after(87) # the effect taken up just before the stop
    notes = notes_on_beats(effect(interrupts: INTERRUPTS, on_tune_tempo: true), songs_on: { SONG_ON => 0 }, stops_on: [92],
                           tunes: { started => tune_step(TUNES.first), stopped => 0 }, asked_on: STILL_ASKED_ON)

    assert_operator notes.count { |at, _| at >= sounding && at < stopped }, :>, 1, "the effect sounding moves on until the stop"
    assert_equal first_notes_from(stopped), notes_from(notes, stopped), "and every effect holds still after it"
  end

  def test_every_effect_names_the_same_tick_count
    one = effect(interrupts: INTERRUPTS, tick_count_at_song_start: 255/256r)
    other = effect(interrupts: INTERRUPTS)
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { sound_effects :sfx, { a: one, b: other } } }

    assert_match(/one count/, error.message)
  end

  def test_a_tick_count_of_a_whole_tick_is_refused
    error = assert_raises(ArgumentError) { effect(interrupts: INTERRUPTS, tick_count_at_song_start: 1).to_song }

    assert_match(/from 0 up to 1/, error.message)
  end

  def test_the_tunes_tempo_without_a_drivers_interrupt_is_refused
    error = assert_raises(ArgumentError) { effect(on_tune_tempo: true).to_song }

    assert_match(/interrupts_per_second/, error.message)
  end

  def test_an_interrupt_slower_than_the_ticks_is_refused
    error = assert_raises(ArgumentError) { effect(interrupts: 30).to_song }

    assert_match(/cannot tick as often/, error.message)
  end

  def test_every_effect_names_the_same_interrupt
    one = effect(interrupts: INTERRUPTS)
    other = effect
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { sound_effects :sfx, { a: one, b: other } } }

    assert_match(/one interrupt/, error.message)
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

    assert_match(/next frame's sound/, error.message)
  end
end
