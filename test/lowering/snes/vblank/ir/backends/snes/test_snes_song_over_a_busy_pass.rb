# frozen_string_literal: true

require "test_helper"
require "stringio"

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

  # The music volume falling tells every note a new loudness, many frames running, and a pass this
  # busy leaves little time to send them. One word waiting a voice keeps that from filling the queue.
  def test_music_fading_over_a_busy_pass_keeps_its_frames_between_the_notes
    run = SNES::HeadlessRun.new.run(fading_game(score(envelope: SHAPE)), frames: 150)
    long = (30...150).select { |pass| run.frames_took(pass) > 1 }

    assert_operator long.length, :<=, MOST_LONG_UNDER_A_FADE, "passes that ran long: #{long.inspect}"
  end

  def test_music_fading_agrees_with_the_interpreter
    SNES::CheckedRun.new.run(fading_game(score(envelope: SHAPE), steps: 1), frames: 100)
    pass
  end

  # Eight parts each holding one long note, so the only thing the music does in the frames measured
  # is take each new level of the fade: find each part's note, give it its loudness and log it. That
  # comes at the start of a pass, where a chord may start too, so it is held to this many lines of
  # the picture on the frame that takes one. Sending the voices their new loudness is not counted:
  # that waits in the sound queue for when the game has time.
  MOST_LINES_A_NEW_LEVEL_TAKES = 15
  NEW_LEVEL_ROUTINES = /\Art_(music_relevel|music_entry|music_loudness|music_scaled|recordings_rescale|recordings_sounding|
                               recordings_heard_volume|sound_group|sound_log)/x
  FADE_STARTS = 70
  NEVER = 30_000

  def test_a_new_music_level_reaching_eight_held_notes_takes_few_lines
    rom = held_notes_game(fade_from: FADE_STARTS).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    lines = lines_by_frame(rom, NEW_LEVEL_ROUTINES, settle: FADE_STARTS, frames: 60)

    assert_operator lines.max, :<=, MOST_LINES_A_NEW_LEVEL_TAKES, "lines a frame: #{lines.map { |each| each.round(1) }.inspect}"
    assert_operator lines.max, :>, 2, "no new level was taken in the frames measured"
  end

  # A chord of eight notes starting while the music fades, a second apart. Each note's start is one
  # entry in the sound queue that carries its loudness with it, so the frame a chord starts on
  # queues eight things and not sixteen, and has this many lines of the picture to spare at least.
  FEWEST_LINES_SPARE_ON_A_CHORD = 163

  def test_a_chord_of_eight_under_a_fade_leaves_most_of_its_frame
    rom = held_notes_game(fade_from: FADE_STARTS, note_frames: 60).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, settle: FADE_STARTS, frames: 130)

    assert_operator result.fewest_lines_spare, :>=, FEWEST_LINES_SPARE_ON_A_CHORD
    assert_equal({ 1 => 130 }, result.passes_by_frames)
  end

  # The lines of the picture each of +frames+ frames spent in the runtime's routines whose labels
  # match +routines+, from the game's pass +settle+ on.
  private def lines_by_frame(rom, routines, settle:, frames:)
    places = rom.built
    labels = places.code.map { |label, address| [address, label] }.sort
    starts = labels.map(&:first)
    VBlank::Diagnostics::Emulator.load_snes!
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: VBlank::Diagnostics::SNESProfiler::FILE_NAME) do |core|
      core.run_frame while core.frames < 3600 && core.wram_read32(places.waits_counted_at) <= settle
      core.take_processor_time # the first ask starts the count
      Array.new(frames) do
        core.run_frame
        clocks = core.take_processor_time.sum do |address, time|
          at = (starts.bsearch_index { |start| start > address } || starts.length) - 1
          !at.negative? && labels[at][1].match?(routines) ? time : 0
        end
        clocks.fdiv(VBlank::Diagnostics::SNESProfiler::LINE_CLOCKS)
      end
    end
  end

  def test_a_fade_over_eight_held_notes_and_a_sound_effect_agrees_with_the_interpreter
    SNES::CheckedRun.new.run(held_notes_game(fade_from: 20, effect_at: 30, note_frames: 40).program, frames: 150)
    pass
  end

  # The first tune's parts play a recording and the second's first part a square voice, so what the
  # player kept about a part's recorded note must not outlast the tune it was a part of.
  def test_a_fade_across_a_change_from_recorded_parts_to_square_ones_agrees_with_the_interpreter
    game = VBlank.game("TWO TUNES", consoles: %i[snes]) do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
      song(:recorded) do
        voice(:high, plays: :piano) { 8.times { note :E4, :half } }
        voice(:low, plays: :piano) { 4.times { note :C4, :whole } }
      end
      song(:square) do
        voice(:lead) { 16.times { note :G4, :half } }
        voice(:under, plays: :piano) { 8.times { note :C4, :whole } }
      end
      play_song :recorded
      passes = var :passes, 0
      game_loop do
        passes += 1
        fade_music_out frames: 60 if passes == 20
        play_song :square if passes == 45
        fade_music_in frames: 60 if passes == 90
      end
    end

    SNES::CheckedRun.new.run(game.program, frames: 170)
    pass
  end

  # +note_frames+ apart the eight parts start a note together, a sound effect beside them so the
  # build is the one a game with effects gets, and the music fades out from pass +fade_from+ and
  # comes back.
  private def held_notes_game(fade_from:, effect_at: NEVER, note_frames: 600)
    score = A::Score
    shape = SHAPE
    VBlank.game("HELD NOTES", consoles: %i[snes]) do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
      parts = Array.new(8) do
        notes = Array.new(600 / note_frames) { |i| score::Note.new(at: i * note_frames, key: i.even? ? :C4 : :E4, length: note_frames - 1) }
        score::Part.new(plays: :piano, envelope: shape, notes: notes)
      end
      music = songs :music, [score.new(parts: parts, tempo: 150, ticks_per_beat: 24, length: 600)]
      hit = score::Note.new(at: 0, key: :G4, length: 24)
      sfx = sound_effects :sfx, { hit: score.new(parts: [score::Part.new(plays: :piano, notes: [hit])], tempo: 150, ticks_per_beat: 24) }
      music.play 0
      passes = var :passes, 0
      game_loop do
        passes += 1
        fade_music_out frames: 96 if passes == fade_from
        fade_music_in frames: 48 if passes == fade_from + 100
        sfx.play 0 if passes == effect_at
      end
    end
  end

  # A pass this size runs long where the notes start whatever is done about the loudness; more than
  # this many means the words about loudness are filling the queue again.
  FADING_PASS = 315
  MOST_LONG_UNDER_A_FADE = 5

  private def fading_game(tune, steps: FADING_PASS)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
      music = songs :music, [tune]
      music.play 0
      fade_music_out frames: 120
      work = var :work, 0
      game_loop { repeat(steps) { work += 1 } }
    end
    b.finalize_program
    b.program
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
