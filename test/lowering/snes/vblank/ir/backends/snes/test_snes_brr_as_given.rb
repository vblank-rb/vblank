# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "brr_recordings"

# A RECORDING GIVEN IN THE SOUND CHIP'S OWN FORMAT (Builder#sample's `brr:`) ON A SUPER NINTENDO: the
# sound unit keeps the game's bytes as they are, and its table points the voice at them and at the
# loop point the game gave (Samples.brr_as_given). What the chip makes of them, heard in bsnes, is held
# sample for sample to the answer key, fullsnes's decoder (BRRRecordings), which is what every other
# build plays (test/all/vblank/builder/test_brr_recordings.rb).
class TestSNESBRRAsGiven < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  VOICE = 4 << 4 # the first voice recordings play on
  ENVX = 0x8
  SOURCE = 0x4
  TABLE = SNES::Runtime::Sound::TABLE_AT

  private def game(bytes, loop_at: 0, loop: true)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      sample(:clip, brr: bytes, brr_loop: loop_at, rate: 32_000).play(loop: loop)
      game_loop { wait_vblank }
    end
    b.finalize_program
    program = b.program
    program.console = :snes
    SNES::CheckedRun.new.run(program, frames: 3)
  end

  # Where the voice's recording starts and loops back to in the sound unit's memory, from its row
  # of the table (fullsnes, "SNES APU DSP BRR Samples": DIR), and the bytes from the start on.
  private def kept(run, size)
    ram = run.apu_ram
    row = TABLE + (run.dsp_registers.getbyte(VOICE + SOURCE) * 4)
    start, loop_point = ram.byteslice(row, 4).unpack("vv")
    [ram.byteslice(start, size).bytes, loop_point - start]
  end

  # THE SAME SAMPLES AS FILTER NOUGHT AT SHIFT 1, each block's sixteen four-bit numbers being the
  # samples themselves: only a recording as quiet as BRRRecordings::QUIET, whose samples are all -8
  # to 7, can be written this way. The answer key's samples, written so the chip has nothing to work out.
  private def written_plainly(samples, last_flags)
    blocks = samples.each_slice(16).to_a
    blocks.each_with_index.flat_map do |block, index|
      [0x10 | (index == blocks.size - 1 ? last_flags : 0)] +
        block.each_slice(2).map { |first, second| ((first & 0xF) << 4) | (second & 0xF) }
    end
  end

  # What bsnes put out of the speakers, sample for sample, for +frames+ of a cartridge that plays
  # +bytes+ round from +loop_at+ from its third pass.
  private def heard(bytes, loop_at, frames)
    cartridge = VBlank.build("BRRHEARD", console: :snes, out: nil, err: nil) do
      enable_sound
      clip = sample :clip, brr: bytes, brr_loop: loop_at, rate: 32_000
      pass = var :pass, 0
      game_loop do
        pass += 1
        clip.play(loop: true) if pass == 3
      end
    end
    Dir.mktmpdir do |folder|
      path = File.join(folder, "heard.sfc")
      cartridge.write(path)
      VBlank::Playthroughs::Probe.open(path) do |probe|
        Array.new(frames) do
          probe.step(1)
          probe.last_frame_sound.samples
        end.flatten
      end
    end
  end

  def test_the_sound_unit_keeps_the_games_bytes_and_loop_point_as_given
    bytes, loop_point = kept(game(BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP), BRRRecordings::QUIET.size)

    assert_equal BRRRecordings::QUIET, bytes
    assert_equal BRRRecordings::QUIET_LOOP, loop_point
  end

  # bsnes decodes the recording, every filter of it, round its loop, and plays exactly what it plays
  # for the answer key's samples handed over plainly: so the chip decodes them as fullsnes says.
  def test_the_chip_plays_the_samples_the_answer_key_decodes
    plainly = written_plainly(BRRRecordings.chip_samples(BRRRecordings::QUIET), 0x03)
    given = heard(BRRRecordings::QUIET, BRRRecordings::QUIET_LOOP, 20)

    assert_operator given.map(&:abs).max, :>=, 10, "the recording is heard"
    assert_equal heard(plainly, BRRRecordings::QUIET_LOOP, 20), given
  end

  # A wrong decoder is heard: the same samples one step out in one place play otherwise.
  def test_one_sample_out_is_heard
    samples = BRRRecordings.chip_samples(BRRRecordings::QUIET)
    samples[40] += 4
    off = heard(written_plainly(samples, 0x03), BRRRecordings::QUIET_LOOP, 20)

    refute_equal heard(BRRRecordings::QUIET, BRRRecordings::QUIET_LOOP, 20), off
  end

  # Played once, a recording that loops ends: its last block's loop bit is cleared, the end bit
  # kept, and the voice falls silent.
  def test_a_looping_recording_played_once_ends
    run = game(BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP, loop: false)
    bytes, = kept(run, BRRRecordings::QUIET.size)

    assert_equal 0x01, bytes[27] & 0x03
    assert_equal BRRRecordings::QUIET.first(27), bytes.first(27)
    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
  end

  # Played once, a recording whose loop takes turns plays as long as the interpreter's decoded
  # samples: its blocks up to the loop point, then the loop's blocks once for each time round they
  # hold, only the last ending it. The checked run holds when it ends to the interpreter's.
  def test_a_loop_that_takes_turns_played_once_plays_every_time_round_the_interpreter_does
    decoded = VBlank::Audio::SNESRecording.new(bytes: BRRRecordings::TAKING_TURNS, loop_at: 18).decoded
    times = (decoded.pcm.bytesize - 32) / 32
    run = game(BRRRecordings::TAKING_TURNS, loop_at: 18, loop: false)
    bytes, = kept(run, 18 + (18 * times))
    wanted = (BRRRecordings::TAKING_TURNS.first(18) + (BRRRecordings::TAKING_TURNS.drop(18) * times)).each_slice(9).map do |block|
      [block.first & ~0x03, *block.drop(1)]
    end.flatten
    wanted[-9] |= 0x01

    assert_operator times, :>, 1
    assert_equal wanted, bytes
    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
  end

  # Played round, a recording that ends goes round the whole of it: its last block's loop bit set,
  # back to its start, and the voice sounds on.
  def test_a_recording_that_ends_played_round_goes_round_from_its_start
    run = game(BRRRecordings::LOUD)
    bytes, loop_point = kept(run, BRRRecordings::LOUD.size)

    assert_equal 0x03, bytes[36] & 0x03
    assert_equal 0, loop_point
    assert_operator run.dsp_registers.getbyte(VOICE + ENVX), :positive?
  end
end
