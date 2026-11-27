# frozen_string_literal: true

require "test_helper"

# A sound driver that wakes on a timer of the sound unit (`sound_driver interrupts_per_second:`) runs
# its songs and its effects on that one timer: each wake adds the tempo to one count, and a song's row
# and an effect's note both fall where the count comes round. The timer divides the sound unit's own
# clock, which runs nearer 32040 samples a second than the 32000 its output is named for (the SNESdev
# wiki, "S-SMP"; fullsnes, "SNES APU"; bsnes apuFrequency), so over a long run a song keeps time with
# those faster wakes, and with the effects that count on them, and not with the named rate.
#
# The answer key is the driver's wakes in real time: wake k at k over the faster rate from power-on, in
# the frame its time falls in, frames counted from 1. Each wake adds the song's tempo step to a count of
# 16 bits, and a tick is where it comes round. The song's start sets the count to 255/256 of a tick,
# counted at that share until it comes round, so the song's first tick is on the first wake from its
# start, and its tick t on the t-th tick after that. An effect counts on the same ticks (`effects_tempo:
# :song`): it starts on the first wake of the frame it is taken up on, and a tick on that wake does not
# move it on.
#
# A song's notes are laid out in frames when the game is built, from its first tick on, and the wakes
# fall at a different place in each frame, so a note is not always on its tick's frame. Its distance
# from that frame stays within a frame either side of one distance, which the count the song's start
# sets gives, and does not change over the run. The effects' notes are worked out on the wakes as the
# game plays, and fall on their tick's frame exactly.
class TestSongOnDriverWakesOnTheSuperNintendo < Minitest::Test
  Score = VBlank::Audio::Score

  WAKES = Rational(8000, 0x60) # the driver's wakes a second, as it names them
  SOUND_UNIT = Rational(32_040, 32_000) # how much faster the sound unit's clock runs than named
  COUNT = 65_536 # the tempo count comes round at this
  STEP = 138 * 256 # what the song's tempo adds to the count on each wake: a whole number of steps
  TICKS_PER_BEAT = 24
  TEMPO = Rational(STEP, COUNT) * WAKES * 60 / TICKS_PER_BEAT # the song's beats a minute at that step
  SONG_NOTE_EVERY = 3 # ticks
  SONG_TICKS = 3600
  FRAMES = 4800
  EFFECT_TICKS = [0, 3, 5].freeze
  EFFECT_PITCHES = [880, 659, 880].freeze # A5, E5, A5
  ASKED_EVERY = 120
  ASKED_ON = 50
  # The pass that asks runs in the frame before the one its ask is taken up in, frames counted from 1.
  TAKEN_UP_AFTER = 2
  # A song's note against its tick: a frame either side of one distance (see above).
  BAND_FRAMES = 2
  # The first notes and the last, about a minute apart, keep that distance on average to a quarter of
  # a frame. Laid out on the clock the sound unit is named for, they move more than a frame apart.
  STRETCH_NOTES = 200
  MOST_DRIFT_FRAMES = 1 / 4r

  private def tune
    notes = (0...SONG_TICKS).step(SONG_NOTE_EVERY).map { |at| Score::Note.new(at: at, key: :C4) }
    Score.new(tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: SONG_TICKS, plays_once: true,
              parts: [Score::Part.new(plays: :noise, notes: notes)])
  end

  private def effect
    notes = EFFECT_TICKS.zip(%i[A5 E5 A5]).map { |at, key| Score::Note.new(at: at, key: key) }
    Score.new(tempo: 125, ticks_per_beat: TICKS_PER_BEAT, length: 8, plays_once: true, parts: [Score::Part.new(notes: notes)])
  end

  private def game
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    tunes = [tune]
    effects = { chime: effect }
    b.instance_eval do
      screen :bitmap
      enable_sound
      sound_driver interrupts_per_second: WAKES, effects_tempo: :song, tick_count_at_song_start: 255 / 256r
      list = sound_effects :sfx, effects
      music = songs :music, tunes
      count = var(:count, 0)
      game_loop do
        music.play 0 if count.zero?
        list.play :chime if count % ASKED_EVERY == ASKED_ON
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # Each note +name+ starts, as [frame, pitch], from the interpreter's log.
  private def notes_of(program, name)
    player = Reference.new
    notes = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| notes << [frame, entry[2].round] if entry.first == :note && entry[1] == name && entry[2].positive? }
      logged = player.audio.size
    end
    player.run(program, frames: FRAMES)
    notes
  end

  # Every tick from the song's start, as [frame, the first wake of its frame], the key above.
  private def ticks
    frame_seconds = VBlank::Console::SUPER_NINTENDO.frame_seconds
    rate = WAKES * SOUND_UNIT
    start = TAKEN_UP_AFTER # the song is asked for on the first pass
    count = until_tick = COUNT - 256 # 255/256 of a tick, set as the song starts
    found = []
    (1..).each do |k|
      frame = (Rational(k) / (rate * frame_seconds)).ceil
      break if frame > FRAMES
      next if frame < start

      first_in_frame = (Rational(k - 1) / (rate * frame_seconds)).ceil < frame
      count += until_tick.nonzero? || STEP
      next if count < COUNT

      until_tick = 0
      count %= COUNT
      found << [frame, first_in_frame]
    end
    found
  end

  # The frame each of the song's notes falls on, its tick's.
  private def song_key = ticks.map(&:first).each_slice(SONG_NOTE_EVERY).map(&:first)

  # Each of the effect's notes as [frame, pitch]: from the frame each ask is taken up on, the ticks after
  # its first wake.
  private def effect_key
    all = ticks
    (ASKED_ON...FRAMES).step(ASKED_EVERY).flat_map do |asked|
      start = asked + TAKEN_UP_AFTER
      own = [start] + all.reject { |frame, first| frame < start || (frame == start && first) }.map(&:first)
      EFFECT_TICKS.zip(EFFECT_PITCHES).filter_map { |tick, pitch| [own[tick], pitch] if own[tick] && own[tick] <= FRAMES }
    end
  end

  def test_a_songs_notes_keep_time_with_the_driver_wakes_over_a_long_run
    program = game
    heard = notes_of(program, :"music.0").map(&:first)
    key = song_key.first(heard.size)

    assert_operator heard.size, :>, 1000, "the song plays on through the run"
    apart = heard.zip(key).map { |frame, ticked| frame - ticked }
    assert_operator apart.max - apart.min, :<=, BAND_FRAMES, "each note within a frame either side of where its tick puts it"
    early, late = [apart.first(STRETCH_NOTES), apart.last(STRETCH_NOTES)].map { |stretch| Rational(stretch.sum, stretch.size) }
    assert_in_delta early, late, MOST_DRIFT_FRAMES, "the notes keep their place against the ticks from the first notes to the last"
  end

  def test_the_effects_notes_fall_on_the_ticks_the_song_counts
    program = game
    game_player.run(program, frames: FRAMES)

    assert_equal effect_key, notes_of(program, :"sfx.chime")
  end
end
