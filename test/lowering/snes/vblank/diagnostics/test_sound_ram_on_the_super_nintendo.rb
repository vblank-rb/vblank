# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "brr_recordings"

# A PORT HOLDS ITS RECORDINGS TO ITS ORIGINAL'S by reading the sound chip's own 64K of memory off the
# running cartridge (Verifier#sound_ram), beside its registers: the DSP's DIR register names the page
# of the chip's table of recordings, four bytes an entry (where a recording starts, then where it loops
# back to), and the entry a voice plays is the number in its SRCN register (fullsnes, "SNES APU DSP BRR
# Samples"). The cartridge here is a small game handing over a recording as BRR, read as a file with no
# build record, as an original is; what the game gave is the answer key.
class TestSoundRAMOnTheSuperNintendo < Minitest::Test
  DIR = 0x5D                       # The DSP register naming the table's page
  RECORDING_VOICE_REGISTERS = 0x40 # The registers of voice 4, the first recordings play on
  SRCN_OFFSET = 0x4                # A voice's register numbering the entry it plays

  # Long enough for the sound chip to take the recording and start the voice on it: the cartridge
  # hands its recordings to the sound chip over its first frames, and the voice starts some frames
  # after the game asks on its third pass.
  FRAMES = 30

  private def with_sound_read
    cartridge = VBlank.build("BRRRAM", console: :snes, out: nil, err: nil) do
      enable_sound
      clip = sample :clip, brr: BRRRecordings::QUIET, brr_loop: BRRRecordings::QUIET_LOOP, rate: 32_000
      pass = var :pass, 0
      game_loop do
        pass += 1
        clip.play(loop: true) if pass == 3
      end
    end
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "brr_ram.sfc").tap { |file| cartridge.write(file) }
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(FRAMES)
        yield probe.reader.sound_ram, probe.reader.sound_registers
      end
    end
  end

  def test_the_sound_ram_holds_the_recording_where_the_table_says_with_its_loop_offset
    with_sound_read do |ram, registers|
      entry = (registers.getbyte(DIR) << 8) + (registers.getbyte(RECORDING_VOICE_REGISTERS + SRCN_OFFSET) * 4)
      start, loop_point = ram.byteslice(entry, 4).unpack("vv")

      assert_equal 64 * 1024, ram.bytesize
      assert_equal BRRRecordings::QUIET, ram.byteslice(start, BRRRecordings::QUIET.size).bytes
      assert_equal BRRRecordings::QUIET_LOOP, loop_point - start
    end
  end
end
