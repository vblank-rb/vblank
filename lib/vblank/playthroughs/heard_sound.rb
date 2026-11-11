# frozen_string_literal: true

module VBlank
  module Playthroughs
    # HOW LOUD ONE CARTRIDGE WAS ON EACH FRAME OF A PLAYING, and what that says of when it was heard.
    #
    # +loudest_by_frame+ is the loudest sample the cartridge put out on each frame
    # (Diagnostics::FrameSound#loudest), frame 1 first. +heard_above+ is the level a frame's loudest
    # sample must be over to count as heard, which the game gives: nought where the emulator's
    # silence is exactly nought, more where a console's speaker is never quite still.
    #
    # The measures are the ones a port holds its sound to its original by. Frames are counted from 1,
    # as a tape counts them, and a cartridge never heard answers nil to each.
    HeardSound = Data.define(:loudest_by_frame, :heard_above) do
      # The sound of +played+ (what Playthrough#play or Tape#play handed back, the cartridge in the
      # emulator): its counted frames, without a lead-in's.
      def self.of(played, heard_above:)
        new(loudest_by_frame: played.game.loudest_by_frame.last(played.frames).freeze, heard_above: heard_above)
      end

      def frames = loudest_by_frame.size

      # The loudest sample on +frame+, 0 for a frame past the end.
      def loudest_on(frame) = loudest_by_frame[frame - 1] || 0

      def heard_on?(frame) = loudest_on(frame) > heard_above
      def heard? = !first_heard.nil?

      # The first and the last frame it is heard on.
      def first_heard = loudest_by_frame.index { |level| level > heard_above }&.succ
      def last_heard = loudest_by_frame.rindex { |level| level > heard_above }&.succ

      # Its level: the loudest sample a frame, averaged over the frames from the first heard to the
      # last, the silent ones between them counted.
      def level
        return unless heard?

        span = loudest_by_frame[(first_heard - 1)..(last_heard - 1)]
        span.sum.fdiv(span.size)
      end

      # The last frame at least half as loud as its loudest frame: where its last sound starts to
      # fall away.
      def fall_starts
        return unless heard?

        half = loudest_by_frame.max / 2.0
        loudest_by_frame.rindex { |level| level >= half } + 1
      end

      # How many frames its last sound takes to fall silent, from #fall_starts to the last frame heard.
      def fall_frames = heard? ? last_heard - fall_starts : nil
    end
  end
end
