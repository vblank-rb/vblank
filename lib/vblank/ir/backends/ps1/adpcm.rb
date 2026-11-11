# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE SOUND CHIP'S OWN WAY OF KEEPING A SOUND: blocks of 16 bytes, each holding 28 samples in four
        # bits apiece. The PlayStation's sound chip (the SPU) plays nothing else: every voice reads these
        # blocks out of the chip's own 512K of sound memory and turns them back into samples of 16 bits as
        # it goes, so the processor writes nothing per sample.
        #
        # A BLOCK (psx-spx, "SPU ADPCM Samples"; Beetle PSX, spu.c SPU_RunDecoder): its first byte holds a
        # shift in its low four bits and a filter in its high four, its second byte flags, and then 14
        # bytes of 28 samples, the low four bits of each byte first. A sample is its four bits, signed,
        # moved to the top of 16 bits and shifted right by the shift (`(int16)(nibble << 12) >> shift`),
        # plus what the filter adds from the two samples before it, in 64ths: (0, 0), (60, 0),
        # (115, -52), (98, -55) or (122, -60). The flags: bit 0 ends the sound here, bit 1 with it goes
        # back to the loop's start rather than going quiet, and bit 2 marks the block where the loop
        # starts. So a sound that loops for ever starts with a block flagged 4 and ends with one flagged 3.
        #
        # Filter 0 adds nothing, so a sample is exactly its four bits at its shift. That is all this
        # encoder makes: the build's own loops are made of a handful of levels and come out exact, and a
        # recording comes out as close as four bits at the best shift for each block can be.
        module ADPCM
          SAMPLES_A_BLOCK = 28
          BLOCK_BYTES = 16

          # The flags of a block (its second byte).
          LOOP_END = 1
          LOOP_REPEAT = 2
          LOOP_START = 4

          # The largest shift there is: psx-spx and Beetle PSX agree on 0 to 12, and treat 13 to 15
          # differently from each other.
          LARGEST_SHIFT = 12

          module_function

          # +samples+ (signed 16-bit numbers, any count) as blocks: padded with silence to a whole block,
          # and, when +loop+, flagged to go round from the first sample for ever, and otherwise to end and
          # go quiet after the last.
          def encode(samples, loop:)
            padded = samples + Array.new((-samples.size) % SAMPLES_A_BLOCK, 0)
            blocks = padded.each_slice(SAMPLES_A_BLOCK).to_a
            blocks = [Array.new(SAMPLES_A_BLOCK, 0)] if blocks.empty?
            blocks.each_with_index.map do |block, i|
              flags = 0
              flags |= LOOP_START if i.zero? && loop
              flags |= LOOP_END | (loop ? LOOP_REPEAT : 0) if i == blocks.size - 1
              encode_block(block, flags)
            end.join
          end

          # One block of 28 samples at the shift that keeps the most of them: the smallest one whose four
          # bits reach the block's largest sample.
          def encode_block(samples, flags)
            shift = shift_for(samples)
            nibbles = samples.map { |sample| nibble_for(sample, shift) }
            bytes = nibbles.each_slice(2).map { |low, high| (low & 0xF) | ((high & 0xF) << 4) }
            [shift, flags, *bytes].pack("C*")
          end

          # The largest shift at which every sample's four bits still reach it. A step of the four bits
          # is 4096 >> shift: a shift of 12 keeps steps of one, a shift of 0 steps of 4096.
          def shift_for(samples)
            LARGEST_SHIFT.downto(0).find { |shift| samples.all? { |sample| unclamped(sample, shift).between?(-8, 7) } } || 0
          end

          def unclamped(sample, shift) = ((sample.to_f * (1 << shift)) / 4096).round

          # The four bits that come nearest +sample+ at +shift+, held to -8..7.
          def nibble_for(sample, shift) = unclamped(sample, shift).clamp(-8, 7)

          # The samples +bytes+ hold, every block's, as the chip reads them: with every filter, so a block
          # another encoder made reads right too.
          WEIGHTS = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60]].freeze

          def decode(bytes)
            older = newer = 0
            bytes.unpack("C*").each_slice(BLOCK_BYTES).flat_map do |shift_filter, _flags, *data|
              shift = shift_filter & 0xF
              first, second = WEIGHTS.fetch(shift_filter >> 4, [0, 0])
              data.flat_map { |byte| [byte & 0xF, byte >> 4] }.map do |nibble|
                signed = nibble >= 8 ? nibble - 16 : nibble
                sample = ((signed << 12) >> shift) + ((older * second) >> 6) + ((newer * first) >> 6)
                sample = sample.clamp(-0x8000, 0x7FFF)
                older = newer
                newer = sample
              end
            end
          end
        end
      end
    end
  end
end
