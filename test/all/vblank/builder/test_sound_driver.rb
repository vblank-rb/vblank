# frozen_string_literal: true

require "test_helper"

# A game describes how its original's sound driver keeps time once (`sound_driver`), rather than on each
# sound effect's Score. The settings a Score already had mean the same described there.
class TestSoundDriver < Minitest::Test
  Score = VBlank::Audio::Score

  WAKES = Rational(8000, 0x60)
  SOUNDED = %i[note sound_effect].freeze # the log's entries that say what was heard

  private def notes = [Score::Note.new(at: 0, key: :A5), Score::Note.new(at: 3, key: :E5), Score::Note.new(at: 5, key: :A5)]

  private def tune = Score.new(tempo: 150, length: 96, parts: [Score::Part.new(plays: :noise, notes: [Score::Note.new(at: 0, key: :C4)])])

  # The game: a tune named on pass 30, and the effect +chime+ asked for every 40 passes.
  private def game(chime, driver: nil)
    music = tune
    b = Builder.new
    b.instance_eval do
      enable_sound
      sound_driver(**driver) if driver
      list = sound_effects :sfx, { chime: chime }
      tunes = songs :music, [music]
      count = var(:count, 0)
      game_loop do
        tunes.play 0 if count == 30
        list.play :chime if count % 40 == 7
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # What the game sounds, each [frame, entry], as the log of the run's own player has it.
  private def heard(program)
    player = game_player
    heard = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| heard << [frame, entry] if SOUNDED.include?(entry.first) }
      logged = player.audio.size
    end
    player.run(program, frames: 400)
    heard
  end

  def test_the_driver_described_once_plays_as_the_same_settings_on_the_score
    on_score = Score.new(tempo: 125, ticks_per_beat: 24, length: 12, plays_once: true, on_timer: true,
                         interrupts_per_second: WAKES, on_tune_tempo: true, tick_count_at_song_start: 255 / 256r,
                         parts: [Score::Part.new(notes: notes)])
    described = Score.new(tempo: 125, ticks_per_beat: 24, length: 12, plays_once: true, parts: [Score::Part.new(notes: notes)])
    driver = { interrupts_per_second: WAKES, effects_tempo: :song, tick_count_at_song_start: 255 / 256r }

    assert_equal heard(game(on_score)), heard(game(described, driver: driver))
  end

  def test_the_driver_is_described_once
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        sound_driver interrupts_per_second: WAKES
        sound_driver interrupts_per_second: WAKES
      end
    end
    assert_match(/once/, error.message)
  end

  def test_the_driver_is_described_before_the_sound
    chime = Score.new(parts: [Score::Part.new(notes: notes)], plays_once: true)
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        enable_sound
        sound_effects :sfx, { chime: chime }
        sound_driver interrupts_per_second: WAKES
      end
    end
    assert_match(/before/, error.message)
  end

  def test_a_wake_named_on_a_score_and_on_the_driver_is_refused
    chime = Score.new(parts: [Score::Part.new(notes: notes)], plays_once: true, on_timer: true, interrupts_per_second: WAKES)
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        enable_sound
        sound_driver interrupts_per_second: WAKES
        sound_effects :sfx, { chime: chime }
      end
    end
    assert_match(/interrupts_per_second/, error.message)
  end

  def test_what_the_driver_does_on_its_wakes_needs_the_wakes
    error = assert_raises(ArgumentError) { VBlank::Audio::SoundDriver.new(effects_start: :on_next_tick) }

    assert_match(/interrupts_per_second/, error.message)
  end

  def test_an_unknown_start_is_refused
    error = assert_raises(ArgumentError) { VBlank::Audio::SoundDriver.new(interrupts_per_second: WAKES, effects_start: :later) }

    assert_match(/on_next_tick/, error.message)
  end

  def test_a_row_is_a_number_from_nought_and_not_this_frame_too
    chime = Score.new(parts: [Score::Part.new(notes: notes)], plays_once: true)
    [[-1, false], [2, true]].each do |row, this_frame|
      error = assert_raises(ArgumentError) do
        Builder.new.instance_eval do
          enable_sound
          list = sound_effects :sfx, { chime: chime }
          list.play :chime, sent_after_rows: row, this_frame: this_frame
        end
      end
      assert_match(/sent_after_rows/, error.message)
    end
  end

  def test_a_music_fade_at_a_row_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        enable_sound
        fade_music_out frames: 30, sent_after_rows: 10
      end
    end
    assert_match(/one frame/, error.message)
  end
end
