# frozen_string_literal: true

module VBlank
  module Playthroughs
    # How loud one cartridge was on each frame of a playing, and what that says of when it was heard.
    #
    # +loudest_by_frame+ is the loudest sample the cartridge put out on each frame
    # (Diagnostics::FrameSound#loudest), the frame after +starts_after+ first. +heard_above+ is the
    # level a frame's loudest sample must be over to count as heard, which the game gives: nought
    # where the emulator's silence is exactly nought, more where a console's speaker is never quite
    # still.
    #
    # The measures are the ones a port holds its sound to its original by. Frames are counted from 1,
    # as a tape counts them, and a cartridge never heard answers nil to each.
    #
    # +starts_after+ is the frame of the tape the playing was heard from the frame after, 0 for
    # power-on (HeardComparison.play's `starting_after:`). The measures are of the frames after it
    # alone, and still counted from power-on: a sound that began before it is heard from the frame
    # after it, and a frame before it is silent.
    #
    # +pitch_by_frame+ is the pitch each of those frames is heard at, in hertz, nil for a frame with
    # none (Diagnostics::FramePitch); nil where the pitch was not asked for, which is wherever more
    # than one voice may be heard.
    HeardSound = Data.define(:loudest_by_frame, :heard_above, :starts_after, :pitch_by_frame) do
      def initialize(loudest_by_frame:, heard_above:, starts_after: 0, pitch_by_frame: nil) = super

      # The sound of +played+ (what Playthrough#play or Tape#play handed back, the cartridge in the
      # emulator): its counted frames, without a lead-in's, or the frames after +starts_after+.
      # +speaker+ :left or :right hears that speaker alone (Verifier#loudest_on_speaker_by_frame).
      # +pitch+ true reads each frame's pitch too (Verifier#pitch_by_frame), for one voice alone.
      def self.of(played, heard_above:, speaker: nil, starts_after: 0, pitch: false)
        loudest = speaker ? played.game.loudest_on_speaker_by_frame(speaker) : played.game.loudest_by_frame
        counted = played.frames - starts_after
        new(loudest_by_frame: loudest.last(counted).freeze, heard_above: heard_above, starts_after: starts_after,
            pitch_by_frame: (played.game.pitch_by_frame(heard_above: heard_above).last(counted).freeze if pitch))
      end

      # How many frames were heard: the frames after the start.
      def frames = loudest_by_frame.size

      # The same sound +frames+ earlier, or later where +frames+ is less than nought, as many frames
      # long: what moves off one end is gone, and the other end is made up with silence.
      def moved(frames)
        return self if frames.zero?

        with(loudest_by_frame: HeardSound.moved_list(loudest_by_frame, frames, 0).freeze,
             pitch_by_frame: pitch_by_frame && HeardSound.moved_list(pitch_by_frame, frames, nil).freeze)
      end

      # +list+ moved +frames+ toward its start, made up at the other end with +silence+.
      def self.moved_list(list, frames, silence)
        return list.drop(frames) + Array.new([frames, list.size].min, silence) if frames.positive?

        Array.new([-frames, list.size].min, silence) + list.first([list.size + frames, 0].max)
      end

      # The pitch on +frame+ in hertz, nil for a frame with none, before the start or past the end.
      def pitch_on(frame)
        return if pitch_by_frame.nil? || frame <= starts_after

        pitch_by_frame[frame - starts_after - 1]
      end

      # The loudest sample on +frame+, 0 for a frame before the start or past the end.
      def loudest_on(frame)
        return 0 if frame <= starts_after

        loudest_by_frame[frame - starts_after - 1] || 0
      end

      def heard_on?(frame) = loudest_on(frame) > heard_above
      def heard? = !first_heard.nil?

      # The first and the last frame it is heard on.
      def first_heard = loudest_by_frame.index { |level| level > heard_above }&.+(starts_after + 1)
      def last_heard = loudest_by_frame.rindex { |level| level > heard_above }&.+(starts_after + 1)

      # Its level: the loudest sample a frame, averaged over the frames from the first heard to the
      # last, the silent ones between them counted.
      def level
        return unless heard?

        level_over(first_heard..last_heard)
      end

      # The loudest sample a frame averaged over +frames+ (a range counted from 1), silent ones counted.
      def level_over(frames) = frames.sum { |frame| loudest_on(frame) }.fdiv(frames.size)

      # The last frame at least half as loud as its loudest frame: where its last sound starts to
      # fall away.
      def fall_starts
        return unless heard?

        half = loudest_by_frame.max / 2.0
        loudest_by_frame.rindex { |level| level >= half } + starts_after + 1
      end

      # How many frames its last sound takes to fall silent, from #fall_starts to the last frame heard.
      def fall_frames = heard? ? last_heard - fall_starts : nil
    end
  end
end
