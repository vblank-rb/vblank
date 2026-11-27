# frozen_string_literal: true

require "test_helper"

# A song bigger than a bank of the cartridge on a Super Nintendo. The player walks a song's notes
# from the cartridge, sixteen bytes a note, and a bank holds 32K, so a song of more than about two
# thousand notes once stopped the build. Its notes now go in banks of their own (SNES::SongBanks),
# and the song plays as the interpreter plays it: the checked run holds the sound log and the DSP's
# registers to the interpreter's on every frame, across the place where one bank of notes ends and
# the next begins. The sound chip's own memory is another thing, and the cartridge reports how much
# of it the game uses.
class TestSNESSongBanks < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  KEYS = %i[C4 D4 E4 F4 G4 A4 B4 C5].freeze

  # A note a frame on the first square part for 2000 frames, so its notes alone fill most of a bank;
  # a second square part that wobbles, a note a frame; a part that plays a recording; and a sound
  # effect over the tune on the first square voice (150 beats a minute at 24 ticks a beat is a frame
  # a tick). The song repeats, so each part's notes are in the table twice, the first play's then
  # the later plays': the first part's take notes 0 to 3999, and the wobbling part's start at 4000
  # and run on past the end of the second bank of notes (4096) on its 97th note.
  LONG = VBlank.game("LONG SONG", consoles: %i[gba snes]) do
    lead = Array.new(2000) { |tick| Note.new(at: tick, key: KEYS[tick % 8], length: 1) }
    wobbling = Array.new(100) { |tick| Note.new(at: tick, key: KEYS[(tick / 3) % 8], length: 1) }
    held = Array.new(30) { |n| Note.new(at: n * 4, key: KEYS[n % 8], length: 4) }
    tune = Score.new(tempo: 150, parts: [Part.new(notes: lead), Part.new(notes: wobbling, vibrato: { depth: 2, speed: 2, after: 0 }),
                                         Part.new(notes: held, plays: :piano)])
    hit = Score.new(tempo: 150, priority: 10, parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 6)])])
    enable_sound
    instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
    music = songs :music, [tune]
    sfx = sound_effects :sfx, { hit: hit }
    pass = 0
    game_loop do
      pass += 1
      music.play 0
      sfx.play :hit if pass == 20 || pass == 70
    end
  end

  # The same length of song under a music volume that moves: the first part slides up on every
  # tenth note, the second steps its shapes and swells into each note, and the recorded part is
  # struck at the level. The second part's notes run past the end of the second bank of notes as
  # LONG's do.
  LEVELLED = VBlank.game("LEVELLED SONG", consoles: %i[gba snes]) do
    lead = Array.new(2000) do |tick|
      Note.new(at: tick, key: KEYS[tick % 8], length: 1, slide_up: (tick % 10).zero? ? :fast : nil)
    end
    swelling = Array.new(100) { |n| Note.new(at: n * 2, key: KEYS[n % 8], length: 2) }
    held = Array.new(30) { |n| Note.new(at: n * 4, key: KEYS[n % 8], length: 4) }
    tune = Score.new(tempo: 150, parts: [Part.new(notes: lead),
                                         Part.new(notes: swelling, duty: %i[eighth half], swell: 2),
                                         Part.new(notes: held, plays: :piano)])
    enable_sound
    instrument :piano, pcm: [60, -60] * 200, rate: 8000, note: :C4, holds_from: 100
    music = songs :music, [tune]
    pass = 0
    game_loop do
      pass += 1
      music.play 0
      music_volume 60 if pass == 40
      music_volume 100 if pass == 150
    end
  end

  # LONG's song beside numbers enough to fill the direct page, each stepped on every pass, and a
  # bar as long as a sum of them showing what the game worked out. The notes apart are read
  # through a pointer on the direct page, so the build holds its room before the numbers take it.
  # A method, not a constant: the game's block holds game code.
  private def crowded_long_song
    lead = Array.new(2000) { |tick| Note.new(at: tick, key: KEYS[tick % 8], length: 1) }
    second = Array.new(100) { |tick| Note.new(at: tick, key: KEYS[(tick / 3) % 8], length: 1) }
    tune = Score.new(tempo: 150, parts: [Part.new(notes: lead), Part.new(notes: second)])
    VBlank.game("CROWDED SONG", consoles: %i[gba snes]) do
      enable_sound
      music = songs :music, [tune]
      many = Array.new(80) { |i| var :"number#{i}", i * 1000 }
      total = var :total, 0
      game_loop do
        music.play 0
        many.each { |number| number.store!(number + 1) }
        total = many[0] + many[79]
        fill_rect 0, 0, 64, 8, :black
        draw_rect_at 0, 0, (total & 63) + 1, 8, :green
      end
    end
  end

  def test_a_song_bigger_than_a_bank_plays_beside_variables_that_fill_the_direct_page
    game = crowded_long_song
    assert_notes_apart(game)
    run = SNES::CheckedRun.new.run(game.program(console: :snes), frames: 130)

    assert_operator run.audio.count { |entry| entry.first == :note }, :>=, 200
  end

  # A try that held the notes' places apart, but whose songs were laid out with their notes in the
  # table, would read every note from the wrong place, so it stops instead.
  def test_notes_held_apart_but_laid_out_in_the_table_stop_the_build
    memory = SNES::Memory.new
    SNES::Runtime::Music.reserve_notes_apart(memory)

    error = assert_raises(SNES::LoweringError) { SNES::Runtime::Music.refuse_notes_held_apart_in_table!(memory) }
    assert_match(/held apart/, error.message)
  end

  def test_a_song_bigger_than_a_bank_plays_as_the_interpreter_plays_it
    assert_notes_apart(LONG)
    run = SNES::CheckedRun.new.run(LONG.program(console: :snes), frames: 130)

    assert_operator run.audio.count { |entry| entry.first == :note }, :>=, 200
    assert_includes run.audio, [:sound_effect, :"sfx.hit"]
  end

  def test_notes_from_banks_of_their_own_slide_step_and_swell_under_the_music_volume
    assert_notes_apart(LEVELLED)
    run = SNES::CheckedRun.new.run(LEVELLED.program(console: :snes), frames: 220)

    assert_operator run.audio.count { |entry| entry.first == :note }, :>=, 200
  end

  # A piece of notes is a whole bank, and the player finds a note's piece from the high bits of its
  # number, so a piece holds a power of two of them.
  def test_a_piece_of_notes_holds_a_power_of_two_of_them
    pieces = SNES::SongBanks::NOTES_A_PIECE

    assert_predicate pieces & (pieces - 1), :zero?
    assert_operator pieces, :>=, 0x100
  end

  # +game+'s cartridge keeps its song notes in pieces of their own, so the test plays that way.
  private def assert_notes_apart(game)
    assert game.build_rom(console: :snes, out: nil, err: nil).built.code.key?(SNES::SongBanks.piece_label(1)), "the notes are apart"
  end

  # A game with one instrument, +samples+ long.
  private def with_piano(samples)
    VBlank.game("PIANO", consoles: %i[gba snes]) do
      enable_sound
      instrument :piano, pcm: [60, -60] * (samples / 2), rate: 8000, note: :C4
      song(:tune) { voice(:lead, plays: :piano) { note :C4, :quarter } }
      game_loop { play_song :tune }
    end
  end

  # How much of the sound chip's memory the cartridge reports: the bytes the game puts there out of
  # its 64K, which grow by the size of a recording in the chip's own format, nine bytes for sixteen
  # samples.
  def test_the_cartridge_reports_how_much_of_the_sound_chips_memory_the_game_uses
    small = with_piano(1600).build_rom(console: :snes, out: nil, err: nil).sound_memory
    big = with_piano(3200).build_rom(console: :snes, out: nil, err: nil).sound_memory

    assert_equal 900, big.used - small.used
    assert_equal 0x10000, small.room
    assert_match(/\ASound memory: [\d.]+ KB of 64 KB\z/, big.line)
  end
end
