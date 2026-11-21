# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# The frame of sound the Advance's mix wrote last (Verifier#last_frame_mix), read out of the
# cartridge's memory: the cartridge's own sound, which two builds of one tune are held alike by.
# The emulator's speaker (#last_frame_samples) is that sound resampled at moments the emulator's
# timing settles, which a game's own transfers into video memory move, so it is not.
class TestMixedFrames < Minitest::Test
  include EmulatorSupport

  CYCLE = 64
  RATE = 15_768
  SINE = (0...CYCLE).map { |i| (Math.sin(i * 2 * Math::PI / CYCLE) * 100).round }.freeze
  RECORDING = (SINE * 40).freeze
  SHAPE = VBlank::Audio::Envelope.new(attack: 100, decay: 20, sustain: 160, release: 30)
  START = 10
  FRAMES = 90
  # Four notes of one recording, a tick a frame, with gaps between some so each falls away.
  NOTES = [[0, :C4, 20], [24, :E4, 10], [30, :G4, 30], [70, :C5, 12]].freeze

  private def tune(envelope: nil)
    notes = NOTES.map { |at, key, length| VBlank::Audio::Score::Note.new(at: at, key: key, length: length, envelope: envelope) }
    VBlank::Audio::Score.new(parts: [VBlank::Audio::Score::Part.new(plays: :keys, notes: notes)], tempo: 3600, ticks_per_beat: 1,
                             length: 100)
  end

  # A game that starts +score+ on pass START, clearing the screen every pass where +busy+, and
  # declares its instrument in the block.
  private def tune_game(score, busy: false, &instrument)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instance_eval(&instrument)
      music = songs :music, [score]
      pass = 0
      game_loop do
        pass += 1
        music.play 0 if pass == START
        clear_screen :black if busy
      end
    end
    b.finalize_program
    b.program
  end

  # Each frame's mix of +program+'s cartridge, for frames frames from power-on.
  private def mixed_frames(program)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MIXED"), frames: 1)
    [console.last_frame_mix] + Array.new(FRAMES - 1) do
      console.step
      console.last_frame_mix
    end
  end

  # The copy a recording is read from with a data pack: the samples, then the rate, the hold and
  # the length, four bytes each, then the envelope's four bytes.
  private def copy_in(folder)
    bytes = RECORDING.pack("c*") + [RATE, 0, RECORDING.length].pack("V3") +
            [SHAPE.attack, SHAPE.decay, SHAPE.sustain, SHAPE.release].pack("C4")
    path = File.join(folder, "copy.bin")
    File.binwrite(path, bytes)
    VBlank::Original::Copy.new(path: path, sha1: Digest::SHA1.hexdigest(bytes), release: "Test", platform: :gba)
  end

  def test_a_recordings_envelope_on_the_instrument_on_each_note_or_from_a_data_pack_mixes_alike
    shape = SHAPE
    recording = RECORDING
    rate = RATE
    on_instrument = tune_game(tune) { instrument :keys, pcm: recording, rate: rate, note: :C4, holds_from: 0, envelope: shape }
    on_each_note = tune_game(tune(envelope: shape)) { instrument :keys, pcm: recording, rate: rate, note: :C4, holds_from: 0 }
    from_pack = Dir.mktmpdir do |folder|
      copy = copy_in(folder)
      count = recording.length
      tune_game(tune) do
        pack = data_pack(from: copy, version: "1") do |slots|
          slots.samples :wave, at: 0, count: count
          slots.numbers :voice, at: count, count: 3, width: :word, signed: false
          slots.numbers :shape, at: count + 12, count: 4, width: :byte, signed: false
        end
        voice = pack[:voice]
        instrument :keys, pcm: pack[:wave], rate: voice.number(0), holds_from: voice.number(1), length: voice.number(2),
                          note: :C4, envelope: pack[:shape].envelope(0)
      end
    end

    heard = mixed_frames(on_instrument)
    assert(heard.any? { |frame| frame.any?(&:nonzero?) }, "the tune sounds")
    assert_equal heard, mixed_frames(on_each_note), "the envelope on each note mixes as the envelope on the instrument"
    assert_equal heard, mixed_frames(from_pack), "the recording and its settings from a data pack mix as given whole"
  end

  def test_a_game_that_clears_the_screen_every_pass_mixes_as_the_same_game_at_rest
    recording = RECORDING
    rate = RATE
    at_rest = tune_game(tune) { instrument :keys, pcm: recording, rate: rate, note: :C4, holds_from: 0 }
    busy = tune_game(tune, busy: true) { instrument :keys, pcm: recording, rate: rate, note: :C4, holds_from: 0 }

    heard = mixed_frames(at_rest)
    assert(heard.any? { |frame| frame.any?(&:nonzero?) }, "the tune sounds")
    assert_equal heard, mixed_frames(busy)
  end

  def test_a_frames_mix_is_the_interpreters
    recording = RECORDING
    rate = RATE
    program = tune_game(tune) { instrument :keys, pcm: recording, rate: rate, note: :C4, holds_from: 0 }
    console = mixed_frames(program).drop_while { |frame| frame.all?(&:zero?) }
    interpreted = Reference.new.run(program, frames: FRAMES).mixed_sound.drop_while { |frame| frame.all?(&:zero?) }

    assert_operator console.length, :>=, 40, "frames with sound in them to compare"
    assert_equal interpreted.first(console.length - 4), console.first(console.length - 4)
  end
end
