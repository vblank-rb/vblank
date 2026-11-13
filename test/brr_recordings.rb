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

  # Where a made-up Super Nintendo original keeps QUIET, and the byte that says where its loop starts;
  # and where it keeps TAKING_TURNS and LOUD, loud enough to be heard in a byte a sample.
  RECORDING_AT = 0x40
  LOOP_POINT_AT = 0x20
  TAKING_TURNS_AT = 0x80
  LOUD_AT = 0xA4
  COPY_BYTES = 0xE0

  # The made-up original, written into +folder+, for a game that reads its recordings from its data pack.
  def self.original_holding(folder)
    copy = "\0".b * COPY_BYTES
    copy[RECORDING_AT, QUIET.size] = QUIET.pack("C*")
    copy[TAKING_TURNS_AT, TAKING_TURNS.size] = TAKING_TURNS.pack("C*")
    copy[LOUD_AT, LOUD.size] = LOUD.pack("C*")
    copy.setbyte(LOOP_POINT_AT, QUIET_LOOP)
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # ENVELOPES AS THE CHIP KEEPS THEM (Audio::SNESEnvelope: adsr1, adsr2, gain), one of each way it
  # moves a level: three ADSR shapes, and GAIN's level held, its climbs, even and bent, and its two
  # falls, which from key-on are silence.
  CHIP_ENVELOPES = Ractor.make_shareable([[0x8E, 0xE0, 0], [0x9F, 0x2A, 0], [0, 0, 0x7F], [0, 0, 0xDC], [0, 0, 0xF8], [0, 0, 0x9C],
                                          [0, 0, 0xA0], [0xFA, 0x74, 0]])
  CHIP_ENVELOPES_AT = 0x80

  # A made-up original holding +bytes+ (64 at most) where QUIET is, and the loop point +loop_point+,
  # written into +folder+ under the name +file+.
  def self.original_with(folder, bytes, loop_point:, file: "made_up_one.bin")
    copy = "\0".b * 0xA0
    copy[RECORDING_AT, bytes.size] = bytes.pack("C*")
    copy[CHIP_ENVELOPES_AT, CHIP_ENVELOPES.flatten.size] = CHIP_ENVELOPES.flatten.pack("C*")
    copy.setbyte(LOOP_POINT_AT, loop_point)
    path = File.join(folder, file)
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "#{file}.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # Its slots: the recording of +count+ bytes, the loop point and the envelopes.
  def self.declare_slots_of(slots, count)
    slots.samples :clip, at: RECORDING_AT, count: count
    slots.numbers :loops, at: LOOP_POINT_AT, count: 1, width: :byte, signed: false
    slots.numbers :chip_envelopes, at: CHIP_ENVELOPES_AT, count: CHIP_ENVELOPES.flatten.size, width: :byte, signed: false
  end

  # Its slots: the recording, and the loop point.
  def self.declare_slots(slots)
    slots.samples :clip, at: RECORDING_AT, count: QUIET.size
    slots.numbers :loops, at: LOOP_POINT_AT, count: 1, width: :byte, signed: false
  end

  # ...and the two loud ones.
  def self.declare_loud_slots(slots)
    slots.samples :turns, at: TAKING_TURNS_AT, count: TAKING_TURNS.size
    slots.samples :loud, at: LOUD_AT, count: LOUD.size
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

  # How many times round its loop a recording is decoded at most (Audio::SNESRecording::MOST_PASSES).
  MOST_PASSES = 16

  # The answer key for a recording that loops, as every build but the Super Nintendo's plays it:
  # [its bytes, the sample a held note reads back to]. Each time round the loop is decided by the
  # two samples it starts from, so it is decoded round until a time round would start from the two
  # an earlier one started from, and holds from there; at most MOST_PASSES times round, holding
  # from the last.
  def self.chip_bytes_round_loop(bytes, loop_at:)
    before = loop_at / 9 * 16
    each = (bytes.size - loop_at) / 9 * 16
    samples = chip_samples(bytes, loop_at: loop_at, loops: MOST_PASSES - 1)
    padded = [0, 0, *samples]
    start_of = ->(pass) { padded[before + (pass * each), 2] }
    (1..MOST_PASSES).each do |passes|
      earlier = (0...passes).find { |pass| start_of.call(pass) == start_of.call(passes) }
      return [samples.first(before + (passes * each)).map { |sample| sample >> 7 }, before + (earlier * each)] if earlier
    end
    [samples.map { |sample| sample >> 7 }, samples.size - each]
  end
end
