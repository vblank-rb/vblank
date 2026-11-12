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
        # Filter 0 adds nothing, so a sample is exactly its four bits at its shift; the others add a
        # guess from the samples before, so the four bits only carry what the guess missed (#encode).
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

          # The filters' weights for the sample before and the one before that, in 64ths (Beetle PSX, spu.c
          # SPU_RunDecoder's Weights; psx-spx gives SPU ADPCM as "reportedly same as for CD-XA").
          WEIGHTS = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60]].freeze

          # +samples+ (signed 16-bit numbers, any count) as blocks: padded with silence to a whole block,
          # and, when +loop+, flagged to go round for ever from sample +loop_from+ (a whole number of blocks
          # in), and otherwise to end and go quiet after the last.
          #
          # EACH BLOCK TAKES THE FILTER AND SHIFT THAT COME NEAREST ITS SAMPLES, every pair tried, each
          # nibble the nearest the decoder can be brought to its sample from where the block before left
          # it, as the chip itself will be. Two blocks take filter 0, which looks at nothing before them:
          # the first, which the chip starts with nothing before it, and the loop's first, which the chip
          # comes to from the loop's end the second time round and from the sample before it the first.
          # A loop made of a few levels, as the build's own are, comes out exact at filter 0.
          def encode(samples, loop:, loop_from: 0)
            padded = samples + Array.new((-samples.size) % SAMPLES_A_BLOCK, 0)
            blocks = padded.each_slice(SAMPLES_A_BLOCK).to_a
            blocks = [Array.new(SAMPLES_A_BLOCK, 0)] if blocks.empty?
            loop_block = loop_from / SAMPLES_A_BLOCK
            history = [0, 0]
            blocks.each_with_index.map do |block, i|
              flags = 0
              flags |= LOOP_START if i == loop_block && loop
              flags |= LOOP_END | (loop ? LOOP_REPEAT : 0) if i == blocks.size - 1
              plain = i.zero? || (loop && i == loop_block)
              bytes, history = encode_block(block, flags, history, filters: plain ? [0] : (0...WEIGHTS.size))
              bytes
            end.join
          end

          # One block: [its bytes, the decoder's last two samples after it], at the filter (of +filters+)
          # and shift whose samples come nearest, from +history+ (the two before it, older first).
          def encode_block(samples, flags, history, filters:)
            best = nil
            filters.each do |filter|
              (0..LARGEST_SHIFT).each do |shift|
                tried = try_block(samples, filter, shift, history)
                best = tried if best.nil? || tried.first < best.first
                break if best.first.zero?
              end
              break if best.first.zero? # exact already: a loop of a few levels stops at filter 0
            end
            _, filter, shift, nibbles, after = best
            bytes = nibbles.each_slice(2).map { |low, high| (low & 0xF) | ((high & 0xF) << 4) }
            [[shift | (filter << 4), flags, *bytes].pack("C*"), after]
          end

          # [the squared error, the filter, the shift, the nibbles, the history after] of +samples+ at
          # +filter+ and +shift+, each nibble the nearest to its sample.
          def try_block(samples, filter, shift, history)
            older, newer = history
            first, second = WEIGHTS.fetch(filter)
            error = 0
            nibbles = samples.map do |sample|
              predicted = ((older * second) >> 6) + ((newer * first) >> 6)
              nibble = (((sample - predicted) * (1 << shift)) / 4096.0).round.clamp(-8, 7)
              decoded = (((nibble << 12) >> shift) + predicted).clamp(-0x8000, 0x7FFF)
              error += (decoded - sample)**2
              older = newer
              newer = decoded
              nibble
            end
            [error, filter, shift, nibbles, [older, newer]]
          end

          # The samples +bytes+ hold, every block's, as the chip reads them: with every filter.

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
