# frozen_string_literal: true

module VBlank
  module Live
    # HOW FAST A PLAY WENT, handed back when it ends. A pass is one time round the game's loop,
    # and a frame is one of the console's sixtieths of a second that went by. A machine that keeps
    # up plays one pass a frame; a slower one plays fewer passes than frames, and the game, which
    # counts one frame a pass, runs that much slower. Fast forward plays more passes than frames,
    # and the game runs that much faster. The seconds run to the end of the last frame
    # the play reached. +stopped_itself+ is a game that halted or came to its end, rather than one
    # the player stopped. +lateness+ is which passes ran longer than a frame (Lateness), or nil
    # played uncapped, where no pass has a frame to be late against.
    #
    # THE PASS THE GAME SETS ITSELF UP IN is in +passes+, +frames+ and +seconds+, and is also
    # +setup_passes+ (1, or 0 where it was played in fast forward, whose frames it shares), the
    # +setup_frames+ it took and the +setup_seconds+ to the end of them. The speeds leave it out, as
    # the Lateness does: a big game can take seconds over it before its first picture and then
    # play at the console's speed.
    Rate = Data.define(:passes, :frames, :seconds, :stopped_itself, :lateness, :setup_passes, :setup_frames, :setup_seconds) do
      def initialize(passes:, frames:, seconds:, stopped_itself: false, lateness: nil, setup_passes: 0, setup_frames: 0, setup_seconds: 0)
        super
      end

      def stopped_itself? = stopped_itself

      # The passes, frames and seconds after the setup.
      def passes_after_setup = passes - setup_passes
      def frames_after_setup = frames - setup_frames
      def seconds_after_setup = seconds - setup_seconds

      def passes_per_second = per_second(passes_after_setup)
      def frames_per_second = per_second(frames_after_setup)

      # What vblank run says when the play stops, for a console whose frame is +console_frame_seconds+
      # long: how fast the game went after its setup, and the setup itself where it took more than a frame.
      def words(console_frame_seconds:)
        speed = format("%<pictures>d frames in %<seconds>.1f s (%<per_second>.1f fps; the console shows %<console>.1f)",
                       pictures: passes_after_setup, seconds: seconds_after_setup, per_second: passes_per_second,
                       console: 1 / console_frame_seconds)
        return speed unless setup_seconds > console_frame_seconds

        format("%<speed>s The game set itself up in %<setup>.1f s before its first picture.", speed: speed, setup: setup_seconds)
      end

      private

      def per_second(count) = seconds_after_setup.positive? ? count / seconds_after_setup.to_f : 0.0
    end
  end
end
