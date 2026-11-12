# frozen_string_literal: true

module VBlank
  module Playthroughs
    # HOW FAR APART TWO CARTRIDGES' HEARD SOUND MAY BE and still be alike. A game gives all three,
    # each with its reason beside it in the game's test: none has a value a comparison assumes.
    #
    #   first_heard_frames_apart  how many frames apart the two may first be heard
    #   level_share_apart         how far apart their levels may be, as a share of the louder one's,
    #                             from 0 to 1 (HeardSound#level)
    #   ending_frames_apart       how many frames apart they may be last heard, and how many frames
    #                             apart their last sounds may take to fall silent (HeardSound#fall_frames)
    HeardTolerances = Data.define(:first_heard_frames_apart, :level_share_apart, :ending_frames_apart) do
      def initialize(first_heard_frames_apart:, level_share_apart:, ending_frames_apart:)
        HeardComparison.refuse_frames_not_count!(:first_heard_frames_apart, first_heard_frames_apart)
        HeardComparison.refuse_frames_not_count!(:ending_frames_apart, ending_frames_apart)
        unless level_share_apart.is_a?(Numeric) && level_share_apart.between?(0, 1)
          raise ArgumentError, "`level_share_apart:` was #{level_share_apart.inspect}. It is a share of the louder " \
                               "cartridge's level, so it must be a number from 0 to 1. `level_share_apart: 0.1` is a tenth."
        end
        super
      end
    end

    # WHERE TWO CARTRIDGES' HEARD SOUND FIRST DIFFERS BY MORE THAN THE GAME ALLOWS.
    #
    # +what+ is which measure was out: +:never_heard+ (one cartridge or both made no sound),
    # +:first_heard+, +:level+, +:last_heard+ or +:fall+. +frame+ is the first frame the two differ
    # on for that reason, counted from 1 (nil where neither was heard), and +loudest+ the loudest
    # sample each put out on it, the first cartridge's and then the second's. +measured+ is the
    # measure itself on each: the frame each was first or last heard on, each one's level, or the
    # frames each one's last sound took to fall silent.
    HeardDifference = Data.define(:what, :frame, :loudest, :measured)

    # TWO CARTRIDGES' HEARD SOUND ON THE SAME PRESSES, IN THE SAME EMULATOR: a port's cartridge beside
    # the original it is made from. The same mixer makes both sounds, so the two can be held close:
    # heard from the same frame, at the same level, and falling silent over the same time.
    #
    #   compared = HeardComparison.play(tape, ours, "original.sfc", heard_above: 0,
    #                                   first_heard_frames_apart: 0, level_share_apart: 0.1,
    #                                   ending_frames_apart: 6)
    #   compared.alike?            # => false
    #   compared.difference.what   # => :level
    #   compared.first.level       # each side is a HeardSound
    #
    # WHAT IS COMPARED, in this order, and the first that is out is the difference: whether each is
    # heard at all; the frame each is first heard on; each one's level over the frames it is heard;
    # the frame each is last heard on; and how many frames each one's last sound takes to fall
    # silent. It is the loudest sample a frame and nothing finer: a wrong note at the right loudness
    # passes. Play the tape past the end of the sound, or the last frame heard is the tape's last.
    #
    # In a test this is Testing::HeardAlike#assert_heard_alike.
    HeardComparison = Data.define(:first, :second, :difference)

    class HeardComparison
      # Play +presses+ (a Tape, or a Playthrough, whose script is played on +first+ and the presses
      # it made on +second+) on both cartridges from power-on, and compare what each put out.
      # +heard_above+ is the loudest sample a silent frame may have (HeardSound), and the rest are
      # HeardTolerances'. +lead_ins+ is a playthrough for each cartridge to play first, not counted
      # (Playthrough#play), for two cartridges that reach the first screen by different roads.
      def self.play(presses, first, second, heard_above:, lead_ins: [nil, nil], **tolerances)
        tolerances = HeardTolerances.new(**tolerances)
        refuse_frames_not_count!(:heard_above, heard_above)
        refuse_lead_ins_not_pair!(lead_ins)
        refuse_unusable_presses!(presses, lead_ins)
        played = presses_led_in(presses, lead_ins[0]).play(first, lead_in: lead_ins[0])
        tape = presses.is_a?(Tape) ? presses : played.tape
        heard = [played, presses_led_in(tape, lead_ins[1]).play(second, lead_in: lead_ins[1])]
        between(*heard.map { |side| HeardSound.of(side, heard_above: heard_above) }, tolerances)
      end

      # The comparison of two HeardSounds, +first+ and +second+, by +tolerances+ (a HeardTolerances).
      def self.between(first, second, tolerances)
        new(first: first, second: second, difference: Differences.new(first, second, tolerances).first_difference)
      end

      def alike? = difference.nil?

      # A tape says whether it was recorded after a lead-in, and is refused played another way. Each
      # cartridge here has a lead-in of its own or none, so each is handed the tape saying its own.
      def self.presses_led_in(presses, lead_in)
        presses.is_a?(Tape) ? presses.started_from(save: nil, led_in: !lead_in.nil?) : presses
      end

      def self.refuse_frames_not_count!(name, given)
        return if given.is_a?(Integer) && !given.negative?

        raise ArgumentError, "`#{name}:` was #{given.inspect}. It must be a whole number, 0 or more."
      end

      def self.refuse_lead_ins_not_pair!(lead_ins)
        return if lead_ins.is_a?(Array) && lead_ins.size == 2

        raise ArgumentError, "`lead_ins:` was #{lead_ins.inspect}. It must be a list of two, the first cartridge's " \
                             "lead-in and then the second's, each a playthrough or nil: `lead_ins: [nil, past_the_logos]`."
      end

      def self.refuse_unusable_presses!(presses, lead_ins)
        unless presses.is_a?(Tape) || presses.is_a?(Playthrough)
          raise ArgumentError, "The presses were #{presses.inspect}. Give a tape (`played.tape`, `Tape.read`) or a " \
                               "playthrough (`VBlank.playthrough`)."
        end
        return unless presses.is_a?(Tape)

        if presses.in_passes
          raise ArgumentError, "This tape counts passes, and the sound is compared frame by frame. To fix this, give a " \
                               "tape of frames: `tape.in_frames_on(cartridge)`."
        end
        if presses.recorded_from_save?
          raise ArgumentError, "This tape was recorded from a save, and the sound is compared from power-on. To fix " \
                               "this, give a tape recorded from power-on."
        end
        return unless presses.recorded_after_lead_in? && lead_ins.compact.empty?

        raise ArgumentError, "This tape was recorded after a lead-in, which is not on the tape. Give the lead-in of " \
                             "each cartridge: `lead_ins: [first_lead_in, second_lead_in]`."
      end
      private_class_method :presses_led_in, :refuse_lead_ins_not_pair!, :refuse_unusable_presses!

      # The checks, each answering a HeardDifference or nil, in the order they are made.
      class Differences
        def initialize(first, second, tolerances)
          @first = first
          @second = second
          @sides = [first, second]
          @tolerances = tolerances
        end

        def first_difference = never_heard || first_heard || level || last_heard || fall

        private

        def difference(what, frame, measured)
          HeardDifference.new(what: what, frame: frame, loudest: frame ? @sides.map { |side| side.loudest_on(frame) } : nil,
                              measured: measured)
        end

        def never_heard
          return if @sides.all?(&:heard?)

          difference(:never_heard, @sides.filter_map(&:first_heard).min, @sides.map(&:first_heard))
        end

        def first_heard
          frames = @sides.map(&:first_heard)
          difference(:first_heard, frames.min, frames) if apart(frames) > @tolerances.first_heard_frames_apart
        end

        # The frame named is the first on which the two frames' loudest samples are further apart than
        # the share, or the first frame either is heard on when no single frame is.
        def level
          levels = @sides.map(&:level)
          return unless apart(levels) > @tolerances.level_share_apart * levels.max

          span = @sides.map(&:first_heard).min..@sides.map(&:last_heard).max
          frame = span.find do |at|
            loudest = @sides.map { |side| side.loudest_on(at) }
            apart(loudest) > @tolerances.level_share_apart * loudest.max
          end
          difference(:level, frame || span.first, levels)
        end

        # The frame named is the first on which one has fallen silent and the other is still heard.
        def last_heard
          frames = @sides.map(&:last_heard)
          difference(:last_heard, frames.min + 1, frames) if apart(frames) > @tolerances.ending_frames_apart
        end

        # The frame named is the first after the earlier of the two starts to fall away.
        def fall
          falls = @sides.map(&:fall_frames)
          difference(:fall, @sides.map(&:fall_starts).min + 1, falls) if apart(falls) > @tolerances.ending_frames_apart
        end

        def apart(pair) = (pair[0] - pair[1]).abs
      end
      private_constant :Differences
    end
  end
end
