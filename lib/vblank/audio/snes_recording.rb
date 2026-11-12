# frozen_string_literal: true

module VBlank
  module Audio
    # A RECORDING AS THE SUPER NINTENDO'S SOUND CHIP KEEPS IT: BRR, the chip's packed format, for a
    # recording taken out of a Super Nintendo game, handed over as it is rather than as samples.
    #
    #   sample :horn, brr: HORN_BRR, brr_loop: 27, rate: 16_000
    #
    # WHAT BRR IS (fullsnes, "SNES APU DSP BRR Samples"). Blocks of nine bytes: a header byte, then
    # sixteen samples of four bits each, the high four bits of a byte first. The header's top four
    # bits are the block's shift, how far each four-bit sample is moved up. The next two are its
    # filter, how each sample is guessed from the two decoded before it so that only the
    # difference is kept: nought guesses nothing, and one to three guess from them in three ways.
    # The low two set what follows the block: bit nought set ends the recording, and bit one set
    # with it goes back to the loop point and carries on. Where the loop point is is not in the
    # bytes: the chip's table of recordings keeps it beside where the recording starts, so a game
    # gives it here as +loop_at+, how many bytes into the recording it is.
    #
    # The Super Nintendo build hands the chip these bytes unchanged. EVERY OTHER BUILD, and the
    # interpreter, plays the samples the chip would decode from them (#decoded), each dropped to
    # the byte a sample those builds mix (the top eight of the chip's sixteen bits), so the game
    # sounds the same everywhere but for that.
    SNESRecording = Data.define(:bytes, :loop_at)

    class SNESRecording
      BLOCK_BYTES = 9
      BLOCK_SAMPLES = 16
      END_BIT = 0x01  # A header's bit that makes its block the last
      LOOP_BIT = 0x02 # ...and, with that one, sends the chip back to the loop point
      MOST_SHIFT = 12 # Shifts above this make nought or -2048, whatever the sample (fullsnes)
      # How many times round a loop is decoded, at most, looking for it to come back to where an
      # earlier time round started (#decoded).
      MOST_PASSES = 16

      # The samples a build that cannot play BRR plays (+pcm+, a byte each, -128..127, as a binary
      # String), and the sample a held note reads back to (+holds_from+, nil for a recording that ends).
      Decoded = Data.define(:pcm, :holds_from)

      def initialize(bytes:, loop_at: 0)
        bytes = bytes.pack("C*") if bytes.is_a?(Array) && bytes.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) }
        unless bytes.is_a?(String)
          raise ArgumentError, "A BRR recording is bytes: a String, or an Array of whole numbers from 0 to 255. " \
                               "You gave #{bytes.class}."
        end

        bytes = bytes.b.freeze
        refuse_broken_blocks!(bytes)
        refuse_misplaced_loop_point!(bytes, loop_at)
        super(bytes: bytes, loop_at: loop_at)
      end

      # Whether the last block sends the chip back to the loop point.
      def loops? = headers.last.allbits?(LOOP_BIT)

      # How many samples one time round the loop is: from the loop point to the end.
      def loop_samples = loops? ? (bytes.bytesize - loop_at) / BLOCK_BYTES * BLOCK_SAMPLES : 0

      # How many samples the recording is, played through once.
      def sample_count = bytes.bytesize / BLOCK_BYTES * BLOCK_SAMPLES

      # THE SAMPLES THE CHIP DECODES, played through once and then, for one that loops, round its
      # loop. Each sample is guessed from the two the chip decoded before it, so the first time round
      # a loop starts from the end of what came before the loop point, and every later time from
      # the end of the time before: they can differ, and a loop can settle into several times round
      # that take turns. A time round is wholly decided by the two samples it starts from, so the
      # loop is decoded over until it would start from two it has started from before; everything
      # after repeats from there, and a held note reads round from there. A loop that has not
      # come back to an earlier start after MOST_PASSES times is held round its last time.
      #
      # The chip starts a recording from the two samples its voice last decoded, which nothing
      # clears. Here they are nought; a recording whose first block guesses from them sounds
      # differently on the chip from one play to the next, which is why recordings start with filter
      # nought.
      def decoded
        blocks = bytes.unpack("C*").each_slice(BLOCK_BYTES).to_a
        samples = [0, 0] # the two before the first, as the chip keeps them
        return Decoded.new(pcm: as_pcm(decode_blocks(blocks, samples)), holds_from: nil) unless loops?

        intro, loop = blocks.partition.with_index { |_, index| index < loop_at / BLOCK_BYTES }
        decode_blocks(intro, samples)
        starts = {} # the two samples each time round started from, to where it starts
        until starts.key?(samples.last(2)) || starts.size == MOST_PASSES
          starts[samples.last(2)] = samples.size - 2
          decode_blocks(loop, samples)
        end
        played = samples.drop(2)
        Decoded.new(pcm: as_pcm(played), holds_from: starts.fetch(samples.last(2), played.size - loop_samples))
      end

      private

      def headers = bytes.unpack("C*").each_slice(BLOCK_BYTES).map(&:first)

      # +blocks+ decoded onto +samples+; the samples they made.
      def decode_blocks(blocks, samples)
        from = samples.size
        blocks.each { |block| decode_block(block, samples) }
        samples.drop(from)
      end

      # THE CHIP'S DECODER, one block onto +samples+ (fullsnes, "SNES APU DSP BRR Samples"; the same
      # arithmetic is decode_brr in blargg's SPC_DSP.cpp, which bsnes plays). A sample is kept as the
      # chip keeps it, its fifteen bits doubled into sixteen; +older+ is the one before last halved
      # back, so the filters' shifts round as the chip's do. Filter one guesses 15/16 of the last
      # sample; two, 61/32 of it less 15/16 of the one before; three, 115/64 of it less 13/16.
      def decode_block(block, samples)
        header, *packed = block
        shift = header >> 4
        filter = (header >> 2) & 3
        packed.flat_map { |byte| [byte >> 4, byte & 0xF] }.each do |nibble|
          sample = nibble >= 8 ? nibble - 16 : nibble
          sample = shift <= MOST_SHIFT ? (sample << shift) >> 1 : (sample.negative? ? -2048 : 0)
          last = samples[-1]
          older = samples[-2] >> 1
          sample += case filter
                    when 1 then (last >> 1) + ((-last) >> 5)
                    when 2 then last - older + (older >> 4) + ((last * -3) >> 6)
                    when 3 then last - older + ((last * -13) >> 7) + ((older * 3) >> 4)
                    else 0
                    end
          # Held to sixteen bits, then doubled, and the bit doubled out of the top is lost: a sample
          # past fifteen bits wraps round, as the chip's does.
          samples << ((((sample.clamp(-0x8000, 0x7FFF) * 2) + 0x8000) & 0xFFFF) - 0x8000)
        end
      end

      # Sixteen-bit samples as a byte each, the top eight bits, as a binary String.
      def as_pcm(samples) = samples.map { |sample| sample >> 8 }.pack("c*")

      def refuse_broken_blocks!(bytes)
        if bytes.empty? || (bytes.bytesize % BLOCK_BYTES).nonzero?
          raise ArgumentError, "A BRR recording is blocks of #{BLOCK_BYTES} bytes, and this one is #{bytes.bytesize} bytes. " \
                               "To fix this, give whole blocks, up to and including the block whose header ends the recording."
        end
        ends = bytes.unpack("C*").each_slice(BLOCK_BYTES).map(&:first).index { |header| header.allbits?(END_BIT) }
        last = (bytes.bytesize / BLOCK_BYTES) - 1
        return if ends == last

        if ends.nil?
          raise ArgumentError, "A BRR recording must end with a block whose header has its end bit set (bit 0), and no " \
                               "block of this one does. The sound chip would read on past it. To fix this, give the " \
                               "recording up to and including its last block."
        end
        raise ArgumentError, "Block #{ends} of this BRR recording ends it, and #{last - ends} more blocks follow. The sound " \
                             "chip never plays them. To fix this, give the recording up to and including block #{ends}."
      end

      def refuse_misplaced_loop_point!(bytes, loop_at)
        return if loop_at.is_a?(Integer) && loop_at >= 0 && (loop_at % BLOCK_BYTES).zero? && loop_at < bytes.bytesize

        raise ArgumentError, "A BRR recording's loop point is #{loop_at.inspect}. The loop point is how many bytes into the " \
                             "recording its loop starts: the start of a block. To fix this, give a multiple of " \
                             "#{BLOCK_BYTES} from 0 to #{bytes.bytesize - BLOCK_BYTES}, the loop address less the start address."
      end
    end
  end
end
