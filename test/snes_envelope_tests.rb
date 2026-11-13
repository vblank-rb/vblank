# frozen_string_literal: true

require "digest"
require "tmpdir"

# AN INSTRUMENT GIVEN THE SUPER NINTENDO SOUND CHIP'S OWN ENVELOPE BYTES (Audio::SNESEnvelope), by
# hand or read from the data pack, on every console whose build shapes a recording: the Advance's
# and the Super Nintendo's. Each console's folder has a test file that includes these:
#
#   test/console/gba/vblank/builder/test_snes_envelope_on_the_advance.rb
#   test/console/snes/vblank/builder/test_snes_envelope_on_the_super_nintendo.rb
#
# What a game can tell of a note, which voice it holds and how far through its shape it is, follows
# the ordinary envelope nearest the chip's bytes on every build, the Super Nintendo's too. So the
# answer key is the same game given that Audio::Envelope by hand. What the Super Nintendo's chip is
# told is test/lowering/snes/vblank/ir/backends/snes/test_snes_chip_envelopes.rb. The bytes read
# from a pack left out, worked into that envelope as the game starts, are test/pack_sound_tests.rb's.
module SNESEnvelopeGames
  # A slow climb, a fall to half and a hold there: attack 5, decay 3, sustain level 3, sustain rate 0.
  ADSR = VBlank::Audio::SNESEnvelope.new(adsr1: 0xB5, adsr2: 0x60, gain: 0x00)
  # GAIN's even climb at rate 10, with ADSR switched off.
  CLIMBING_GAIN = VBlank::Audio::SNESEnvelope.new(adsr1: 0x00, adsr2: 0x00, gain: 0xCA)

  # A second of a sine, and a tempo where one tick is one frame.
  RECORDING = (0...8000).map { |i| (Math.sin(i * 2 * Math::PI / 64) * 100).round }.freeze
  TEMPO = 150
  NOTE_FRAMES = 40

  # The made-up original holds the ADSR bytes here, after three bytes of another instrument's.
  SHAPES_AT = 0x20

  private def original_with_shapes(folder)
    copy = "\0".b * 0x40
    copy[SHAPES_AT, 6] = [0x8F, 0xE0, 0x00, ADSR.adsr1, ADSR.adsr2, ADSR.gain].pack("C*")
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game whose song plays one note of NOTE_FRAMES frames on an instrument shaped by +envelope+,
  # or, given +from+ (an original), by the second envelope its data pack holds.
  private def shaped_note_game(envelope, from: nil)
    score = VBlank::Audio::Score
    tune = score.new(tempo: TEMPO, length: 90, plays_once: true,
                     parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :C4, length: NOTE_FRAMES)])])
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      if from
        pack = data_pack(from: from, version: "1") { |slots| slots.numbers :shapes, at: SHAPES_AT, count: 6, width: :byte, signed: false }
        envelope = pack[:shapes].snes_envelope(1)
      end
      instrument :tone, pcm: RECORDING, rate: 8000, note: :C4, holds_from: 0, envelope: envelope
      music = songs :music, [tune]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # A game whose instrument has no envelope of its own, and whose song plays one note of it
  # shaped by its part's envelope (+part+) or the note's own (+note+).
  private def own_envelope_game(part: nil, note: nil)
    score = VBlank::Audio::Score
    notes = [score::Note.new(at: 0, key: :C4, length: NOTE_FRAMES, envelope: note)]
    tune = score.new(tempo: TEMPO, length: 90, plays_once: true, parts: [score::Part.new(plays: :tone, envelope: part, notes: notes)])
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: RECORDING, rate: 8000, note: :C4, holds_from: 0
      music = songs :music, [tune]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

module SNESEnvelopeTests
  include SNESEnvelopeGames

  # What the run has sounding, and how far through its shape, after each of +frames+.
  private def levels_at(program, frames)
    frames.map do |count|
      run = game_player.run(program, frames: count)
      [run.active_samples, run.level_of(:tone)]
    end
  end

  # Early in the climb, later in it, holding, and after the note has ended.
  WATCHED = [4, 14, 36, NOTE_FRAMES + 6].freeze

  def test_an_instrument_given_the_chips_adsr_bytes_plays_the_nearest_envelope
    wanted = levels_at(shaped_note_game(ADSR.closest_envelope), WATCHED)
    played = levels_at(shaped_note_game(ADSR), WATCHED)

    early, later, holding, ended = wanted

    assert_operator early.last, :<, later.last, "the nearest envelope climbs as the chip's slow attack does"
    assert_in_delta 128, holding.last, 4, "and holds at the chip's sustain level, half"
    assert_empty ended.first, "and the voice comes free once the note has ended"
    assert_equal wanted, played
  end

  def test_an_instrument_given_the_chips_gain_byte_plays_the_nearest_envelope
    wanted = levels_at(shaped_note_game(CLIMBING_GAIN.closest_envelope), WATCHED)
    played = levels_at(shaped_note_game(CLIMBING_GAIN), WATCHED)

    assert_operator wanted[0].last, :<, wanted[1].last, "the nearest envelope climbs as the chip's GAIN does"
    assert_equal VBlank::Audio::Envelope::FULL, wanted[2].last
    assert_equal wanted, played
  end

  # One instrument serves every shape: the bytes go on the part, or on the note.
  def test_a_part_given_the_chips_bytes_plays_the_nearest_envelope
    wanted = levels_at(own_envelope_game(part: ADSR.closest_envelope), WATCHED)
    played = levels_at(own_envelope_game(part: ADSR), WATCHED)

    assert_operator wanted[0].last, :<, wanted[1].last, "the part's shape climbs, where the instrument's own would sound flat out"
    assert_equal wanted, played
  end

  def test_a_note_given_the_chips_bytes_plays_the_nearest_envelope_in_place_of_its_parts
    wanted = levels_at(own_envelope_game(part: ADSR, note: CLIMBING_GAIN.closest_envelope), WATCHED)
    played = levels_at(own_envelope_game(part: ADSR, note: CLIMBING_GAIN), WATCHED)

    assert_equal VBlank::Audio::Envelope::FULL, wanted[2].last, "GAIN's climb reaches the top, where the part's ADSR holds at half"
    assert_equal wanted, played
  end

  # A key-on starts the chip's level at nothing, and this GAIN only takes it down.
  def test_a_gain_that_only_falls_holds_its_voice_in_silence
    falling = VBlank::Audio::SNESEnvelope.new(adsr1: 0x00, gain: 0x9F)
    early, held, = levels_at(shaped_note_game(falling), WATCHED)

    assert_equal [[:tone], 0], early
    assert_equal [[:tone], 0], held
  end

  def test_the_chips_bytes_read_from_the_data_pack_play_as_the_same_bytes_given
    Dir.mktmpdir do |folder|
      wanted = levels_at(shaped_note_game(ADSR), WATCHED)
      played = levels_at(shaped_note_game(nil, from: original_with_shapes(folder)), WATCHED)

      assert_equal [:tone], wanted.first.first
      assert_equal wanted, played
    end
  end

  def test_an_envelope_past_the_end_of_its_slot_is_refused
    Dir.mktmpdir do |folder|
      pack = VBlank::Builder.new.data_pack(from: original_with_shapes(folder), version: "1") do |slots|
        slots.numbers :shapes, at: SHAPES_AT, count: 6, width: :byte, signed: false
      end
      error = assert_raises(ArgumentError) { pack[:shapes].snes_envelope(2) }

      assert_includes error.message, "no envelope 2"
    end
  end
end
