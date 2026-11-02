# frozen_string_literal: true

require "test_helper"

# A GAME'S FRAME IS THE GAME'S. A pass this busy keeps one frame with no song, and it must keep one
# with seven parts sounding over it, their loudness changing on every frame. One pass in a run of
# several may be long where all seven notes start; a stretch of long passes means the song is
# stealing frames.
class TestSNESSongOverABusyPass < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  A = VBlank::Audio
  STEPS = 320
  # Few enough that the pass after all seven notes start ends in the blank, not past it.
  ENDS_IN_THE_BLANK = 285
  EVERY = 60
  SHAPE = A::Envelope.new(attack: 16, decay: 250, sustain: 100, release: 250)

  def test_a_pass_nearly_filling_its_frame_keeps_it_between_the_notes_of_a_shaped_song
    run = SNES::HeadlessRun.new.run(busy_game(score(envelope: SHAPE)), frames: 150)
    long = (30...150).select { |pass| run.frames_took(pass) > 1 }

    assert_operator long.length, :<=, 6, "passes that ran long: #{long.inspect}"
  end

  # Where all seven notes start the pass begins late and ends a little into the blank. The blank has
  # time left to show it, so the game keeps its frame rather than waiting for the next one.
  def test_a_pass_that_ends_early_in_the_blank_keeps_its_frame
    run = SNES::HeadlessRun.new.run(busy_game(score(envelope: SHAPE), steps: ENDS_IN_THE_BLANK), frames: 150)
    long = (30...150).select { |pass| run.frames_took(pass) > 1 }

    assert_empty long, "passes that ran long"
  end

  def test_a_shaped_song_and_notes_that_end_agree_with_the_interpreter
    SNES::CheckedRun.new.run(short_notes_game, frames: 120)
    pass
  end

  private def score(envelope:)
    part = lambda do
      notes = (0...(1200 / EVERY)).map do |i|
        A::Score::Note.new(at: i * EVERY, key: i.even? ? :C4 : :E4, length: EVERY - 1)
      end
      A::Score::Part.new(plays: :piano, envelope: envelope, notes: notes)
    end
    A::Score.new(parts: Array.new(7) { part.call }, tempo: 150, ticks_per_beat: 24, length: 1200)
  end

  private def busy_game(tune, steps: STEPS)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
      music = songs :music, [tune]
      music.play 0
      work = var :work, 0
      game_loop { repeat(steps) { work += 1 } }
    end
    b.finalize_program
    b.program
  end

  # Recordings played once that end while the tune goes on, others that hold: the places come free on
  # the frames the interpreter frees them.
  private def short_notes_game
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :drum, pcm: [60, -60] * 300, rate: 8000, note: :C4
      instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
      song(:title) do
        voice(:hit, plays: :drum) { 16.times { note :C4, :eighth } }
        voice(:held, plays: :piano) { 8.times { note :E4, :quarter } }
      end
      play_song :title
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end
