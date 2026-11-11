# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A RUNNING CARTRIDGE PUT OUT OF ITS SPEAKERS ON ONE FRAME, the same on every console whose
    # emulator hands its sound over (Verifier#last_frame_sound).
    #
    # +samples+ are the frame's samples as the emulator mixed them: whole numbers from -32768 to
    # 32767, the left speaker's and the right's by turns, left first. How many a frame holds is the
    # console's own, since each emulator makes sound at its console's rate, and it is not the same on
    # every frame: a console's sound clock and its picture clock do not divide evenly.
    #
    # +loudest+ is the furthest any of them is from nought, on either speaker: 0 for a frame of
    # silence, 32768 at most. It is the one measure of how loud a frame was that two cartridges in
    # the same emulator are compared by (Playthroughs::HeardSound), because the same mixer made both.
    FrameSound = Data.define(:samples, :loudest) do
      # The frame whose sound the emulator handed over as +bytes+: 16 bits a sample, low byte first.
      def self.from_bytes(bytes)
        samples = bytes.unpack("s<*").freeze
        new(samples: samples, loudest: loudest_of(samples))
      end

      # The furthest any of +samples+ is from nought.
      def self.loudest_of(samples) = samples.empty? ? 0 : samples.minmax.map(&:abs).max

      # Each speaker's samples alone.
      def left = samples.each_slice(2).map(&:first)
      def right = samples.each_slice(2).filter_map { |pair| pair[1] }

      def silent? = loudest.zero?
    end
  end
end
