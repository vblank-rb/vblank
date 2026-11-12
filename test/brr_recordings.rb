# frozen_string_literal: true

require "digest"

# MADE-UP RECORDINGS IN THE SUPER NINTENDO SOUND CHIP'S OWN FORMAT (BRR, Audio::SNESRecording), and
# the answer key they are decoded by: the chip's decoder as fullsnes writes it ("SNES APU DSP BRR
# Samples"), worked in fifteen-bit samples, where Audio::SNESRecording works in the doubled sixteen
# bits the chip keeps. Shared by the decoder's own test (test/all/vblank/audio/test_snes_recording.rb),
# the games every run plays (test/all/vblank/builder/test_brr_recordings.rb) and the Super
# Nintendo's, which hold the answer key to what bsnes plays
# (test/lowering/snes/vblank/ir/backends/snes/test_snes_brr_as_given.rb).
module BRRRecordings
  # Every filter, every way a sample can come out: block 0 filter 0 at shift 12; block 1 filter 1 at
  # shift 8; block 2 filter 2 at shift 9; block 3 filter 3 at shift 13, past the shifts fullsnes
  # names, where a sample is -2048 or nought, and where the guess passes fifteen bits and wraps; block
  # 4 filter 3 at shift 7, ending the recording without a loop.
  LOUD = [0xC0, 0x78, 0x10, 0xF2, 0x3D, 0x4C, 0x5B, 0x6A, 0x31,
          0x84, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD5,
          0x98, 0x1F, 0x2E, 0x3D, 0x4C, 0x00, 0x00, 0x78, 0x00,
          0xDC, 0xF1, 0x87, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x7D, 0x5B, 0x5B, 0x00, 0x00, 0x12, 0x34, 0xEF, 0x00].freeze

  # A wave about nought, quiet enough that every sample the chip decodes, before it is doubled, is
  # -8 to 7: filter 0, then 1, 2 and 3, each at shift 1, the last block looping back to block 2 (18
  # bytes in). Its loop starts from the same two samples every time round, so every time round is the
  # same. Being that quiet, a recording of filter 0 at shift 1 holds the same samples exactly, which
  # is how the Super Nintendo's test hears it in bsnes.
  QUIET = [0x10, 0x02, 0x35, 0x66, 0x65, 0x43, 0x1F, 0xDC, 0xBA,
           0x14, 0x00, 0x12, 0x12, 0x22, 0x32, 0x11, 0x00, 0xB2,
           0x18, 0xEF, 0x21, 0x12, 0x12, 0x20, 0x21, 0x02, 0x00,
           0x1F, 0x10, 0x11, 0x01, 0x02, 0x10, 0x11, 0x22, 0x02].freeze
  QUIET_LOOP = 18

  # The same wave nudged otherwise at the ends of blocks 1 and 2, and every block at shift 9, so it is
  # loud and its loop's first time round starts from other samples than the later ones: the loop
  # comes back to where it started only after five times round, which take turns from then on.
  TAKING_TURNS = [0x90, 0x02, 0x35, 0x66, 0x65, 0x43, 0x1F, 0xDC, 0xBA,
                  0x94, 0x00, 0x12, 0x12, 0x22, 0x32, 0x11, 0x00, 0x0F,
                  0x98, 0x10, 0x21, 0x12, 0x12, 0x20, 0x21, 0x02, 0x00,
                  0x9F, 0x10, 0x11, 0x01, 0x02, 0x10, 0x11, 0x22, 0x02].freeze

  # Where a made-up Super Nintendo original keeps QUIET, and the byte that says where its loop starts.
  RECORDING_AT = 0x40
  LOOP_POINT_AT = 0x20

  # The made-up original, written into +folder+, for a game that reads QUIET from its data pack.
  def self.original_holding(folder)
    copy = "\0".b * 0x80
    copy[RECORDING_AT, QUIET.size] = QUIET.pack("C*")
    copy.setbyte(LOOP_POINT_AT, QUIET_LOOP)
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # Its slots: the recording, and the loop point.
  def self.declare_slots(slots)
    slots.samples :clip, at: RECORDING_AT, count: QUIET.size
    slots.numbers :loops, at: LOOP_POINT_AT, count: 1, width: :byte, signed: false
  end

  # THE ANSWER KEY: +bytes+ decoded through to the end and then +loops+ times round from +loop_at+,
  # as fifteen-bit samples, the chip's decoder as fullsnes writes it. The two before the first are
  # nought.
  def self.chip_samples(bytes, loop_at: 0, loops: 0)
    blocks = bytes.each_slice(9).to_a
    old = older = 0
    (blocks + (blocks.drop(loop_at / 9) * loops)).flat_map do |header, *packed|
      shift = header >> 4
      filter = (header >> 2) & 3
      packed.flat_map { |byte| [byte >> 4, byte & 0xF] }.map do |nibble|
        sample = nibble >= 8 ? nibble - 16 : nibble
        sample = shift <= 12 ? (sample << shift) >> 1 : (sample.negative? ? -2048 : 0)
        sample += case filter
                  when 1 then old + ((-old) >> 4)
                  when 2 then (old * 2) + ((-old * 3) >> 5) - older + (older >> 4)
                  when 3 then (old * 2) + ((-old * 13) >> 6) - older + ((older * 3) >> 4)
                  else 0
                  end
        # Held to sixteen bits, then to fifteen, wrapping.
        sample = ((sample.clamp(-0x8000, 0x7FFF) + 0x4000) & 0x7FFF) - 0x4000
        older = old
        old = sample
      end
    end
  end

  # ...as a byte each, as every build but the Super Nintendo's plays them: the top eight bits.
  def self.chip_bytes(bytes, loop_at: 0, loops: 0) = chip_samples(bytes, loop_at: loop_at, loops: loops).map { |sample| sample >> 7 }
end
