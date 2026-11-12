# frozen_string_literal: true

module VBlank
  module Audio
    # WHERE A NOTE SITS BETWEEN THE SPEAKERS — the left, the right, both, or a shade between.
    #
    # The console has two speakers (or the two sides of a pair of headphones). A part names :left,
    # :right or :center, or a number from -1.0 (the left speaker alone) to 1.0 (the right alone),
    # where 0 is both, as :center is. A shade turns the far side down and leaves the near side
    # whole: -0.5 plays from the left at full and from the right at half, as a balance knob does,
    # so a part moved off the middle is never quieter on its own side than a part in it.
    #
    # +left+ and +right+ are how much of the note each speaker hears, out of SHARE_FULL.
    #
    # WHAT EACH VOICE CAN DO WITH A SHADE. The Advance's four voices of its own (the two squares, the
    # wave and the noise) are sent to the left speaker, the right or both by a switch per voice and
    # per side, and nothing between. Every console plays those four as the Advance does, so a shade
    # there is the nearest of the three (#side): one side alone when it is at least twice the other,
    # as a Game Boy Advance game's own sound driver chooses (m4a's CgbPan), and both otherwise. The
    # music player sets a voice's switches as each note starts, so a part can move from side to side,
    # and the game's own `beep`, `noise` and `wave` send their voice to both again.
    #
    # A part that plays a recording sits where its shade says on a console whose sound chip has a
    # volume for each side of each voice (the Super Nintendo's). Where every recording is mixed into
    # one stream, as on the Advance, that stream plays from both speakers, and so does the part.
    Pan = Data.define(:left, :right)

    class Pan
      # A side heard whole, and the shift that divides by it.
      SHARE_FULL = 64
      SHARE_SHIFT = 6
      # ...and what is added before that shift to round a loudness times a share to the nearest step.
      SHARE_ROUNDING = SHARE_FULL / 2

      # The two shares as one word for a console's table: the left in the low byte, the right in the
      # next. +pan+ nil is the middle.
      def self.shares_word(pan)
        pan ||= CENTER
        pan.left | (pan.right << 8)
      end

      LEFT = new(left: SHARE_FULL, right: 0)
      RIGHT = new(left: 0, right: SHARE_FULL)
      CENTER = new(left: SHARE_FULL, right: SHARE_FULL)

      SIDES = { left: LEFT, right: RIGHT, center: CENTER }.freeze

      # Where a part or a note GAVE it sits: :left, :right or :center, or a number from -1.0 to 1.0,
      # or nil when it gave nothing. +where+ names who gave it, as the start of a sentence.
      def self.said(side, where:)
        return nil if side.nil?
        return shade(side) if side.is_a?(Numeric) && side.between?(-1, 1)

        SIDES.fetch(side) do
          raise ArgumentError, "#{where} says `pan: #{side.inspect}`. A note plays from :left, :right, :center " \
                               "for both speakers, or a number from -1.0 for the left alone to 1.0 for the right " \
                               "alone. To fix this, give one of those."
        end
      end

      # The Pan of +position+ (-1.0 to 1.0): the near side whole, the far side less by how far off the
      # middle it is, to the nearest SHARE_FULLth.
      def self.shade(position)
        far = (SHARE_FULL * (1 - position.abs)).round
        position.negative? ? new(left: SHARE_FULL, right: far) : new(left: far, right: SHARE_FULL)
      end

      # The side a note plays from on a voice that only switches between speakers, as the log names
      # it: :left or :right, or nil for both (see the note above the class).
      def self.side_of(pan)
        return nil if pan.nil?
        return :left if pan.left >= pan.right * 2
        return :right if pan.right >= pan.left * 2

        nil
      end

      # Whether +pan+ is heard whole from both speakers, as a note that names nothing is.
      def self.centered?(pan) = pan.nil? || pan == CENTER

      # The two bits a note keeps its side in: 1 for the left alone, 2 for the right alone, and
      # nought for both, so a note that names no side is a note that plays from both.
      LEFT_BITS = 1
      RIGHT_BITS = 2

      BITS = { left: LEFT_BITS, right: RIGHT_BITS }.freeze

      # The bits a note keeps +side+ in (:left, :right, or nil for both), and the side back from them.
      def self.bits_of(side) = BITS.fetch(side, 0)
      def self.side_from_bits(bits) = BITS.key(bits)
    end
  end
end
