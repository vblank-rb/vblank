# frozen_string_literal: true

require "test_helper"

# AN INSTRUMENT GIVEN THE SOUND CHIP'S OWN ENVELOPE BYTES (Audio::SNESEnvelope) has them written to
# its voice unchanged. Read on the cartridge's own sound chip in the emulator: the voice's ADSR1,
# ADSR2 and GAIN registers hold the bytes the instrument was given, its volume registers hold the
# note's loudness whole while the chip moves the level itself (ENVX, which only the chip writes),
# and its key-off ends the note.
class TestSNESChipEnvelopes < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  SNESEnvelope = VBlank::Audio::SNESEnvelope
  Score = VBlank::Audio::Score

  # A voice's registers, counted from its first.
  VOLUME_LEFT = 0x0
  ADSR1 = 0x5
  ENVX = 0x8

  # A slow climb, a fall to half and a hold there; and GAIN's even climb, under ADSR bytes whose
  # top bit is clear, so the chip reads GAIN and the ADSR2 byte is only carried.
  ADSR = SNESEnvelope.new(adsr1: 0xB5, adsr2: 0x60, gain: 0x12)
  CLIMBING_GAIN = SNESEnvelope.new(adsr1: 0x35, adsr2: 0x47, gain: 0xCA)

  NOTE_FRAMES = 40

  private def one_note(plays: :tone)
    Score.new(tempo: 150, length: 90, plays_once: true,
              parts: [Score::Part.new(plays: plays, notes: [Score::Note.new(at: 0, key: :C4, length: NOTE_FRAMES)])])
  end

  # A game with an instrument :tone shaped by +envelope+ and a plain one, :plain, and whatever the
  # block plays.
  private def game(envelope, &plays)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      @tone = instrument :tone, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100, envelope: envelope
      @plain = instrument :plain, pcm: [50, -50] * 4000, rate: 8000, note: :C4, holds_from: 100
      instance_exec(&plays)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  private def song_game(envelope, tune = one_note)
    game(envelope) do
      music = songs :music, [tune]
      music.play 0
    end
  end

  # The registers of the voice the game's first recording plays on, +frames+ in.
  private def first_voice_registers(program, frames:)
    dsp = SNES::CheckedRun.new.run(program, frames: frames).dsp_registers
    voice = SNES::Music.recording_voices(program).first
    dsp.byteslice(voice << 4, 16).bytes
  end

  private def envelope_bytes(registers) = registers[ADSR1, 3]

  def test_a_songs_note_writes_the_adsr_bytes_unchanged
    assert_equal [0xB5, 0x60, 0x12], envelope_bytes(first_voice_registers(song_game(ADSR), frames: 10))
  end

  def test_a_songs_note_writes_the_gain_byte_unchanged
    assert_equal [0x35, 0x47, 0xCA], envelope_bytes(first_voice_registers(song_game(CLIMBING_GAIN), frames: 10))
  end

  def test_the_chip_moves_the_level_and_the_volume_stays_whole
    program = song_game(ADSR)
    early = first_voice_registers(program, frames: 6)
    later = first_voice_registers(program, frames: 16)
    holding = first_voice_registers(program, frames: 36)

    assert_operator early[ENVX], :<, later[ENVX], "the chip's own level climbs by its slow attack"
    assert_in_delta 0x40, holding[ENVX], 2, "and holds at its sustain level, half of 127"
    assert_operator early[VOLUME_LEFT], :>, 0
    assert_equal [early[VOLUME_LEFT]] * 2, [later[VOLUME_LEFT], holding[VOLUME_LEFT]],
                 "the volume registers hold the note's loudness whole from its first frame"
  end

  def test_the_note_ending_keys_its_voice_off
    registers = first_voice_registers(song_game(ADSR), frames: NOTE_FRAMES + 6)

    assert_equal 0, registers[ENVX], "a key-off takes the chip's level to nothing inside a frame"
  end

  def test_a_note_given_no_chip_envelope_sounds_flat_out_beside_one_that_is
    registers = first_voice_registers(song_game(ADSR, one_note(plays: :plain)), frames: 10)

    assert_equal [0x00, 0x00, 0x7F], envelope_bytes(registers), "ADSR off, and GAIN fixed at the top"
  end

  def test_a_parts_own_envelope_is_played_in_place_of_the_instruments_chip_bytes
    shape = VBlank::Audio::Envelope.new(attack: 16, decay: 250, sustain: 100, release: 250)
    tune = Score.new(tempo: 150, length: 90, plays_once: true,
                     parts: [Score::Part.new(plays: :tone, envelope: shape, notes: [Score::Note.new(at: 0, key: :C4, length: NOTE_FRAMES)])])

    assert_equal [0x00, 0x00, 0x7F], envelope_bytes(first_voice_registers(song_game(ADSR, tune), frames: 10))
  end

  # With no song the game's writes go to the sound chip at once, not through the queue.
  def test_the_games_own_play_writes_the_bytes_unchanged
    program = game(ADSR) { @tone.play(:C4) }

    assert_equal [0xB5, 0x60, 0x12], envelope_bytes(first_voice_registers(program, frames: 10))
  end

  # In a game with sound effects the sound chip's own program writes a note's registers, told
  # the envelope's bytes first.
  def test_a_sound_effects_note_writes_the_bytes_unchanged
    effect = one_note
    program = game(CLIMBING_GAIN) do
      sounds = sound_effects :sfx, { ding: effect }
      sounds.play :ding
    end
    early = first_voice_registers(program, frames: 8)
    later = first_voice_registers(program, frames: 20)

    assert_equal [0x35, 0x47, 0xCA], envelope_bytes(later)
    assert_operator early[ENVX], :<, later[ENVX], "GAIN climbs by itself"
  end

  def test_only_a_game_with_a_chip_envelope_carries_the_routines_for_one
    ordinary = VBlank::Audio::Envelope.new(attack: 16, decay: 250, sustain: 100, release: 250)

    refute SNES::Lowering::Sound.chip_envelopes?(song_game(ordinary))
    assert SNES::Lowering::Sound.chip_envelopes?(song_game(ADSR))
  end
end
