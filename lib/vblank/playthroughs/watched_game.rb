# frozen_string_literal: true

module VBlank
  module Playthroughs
    # A PLAYTHROUGH A PERSON CAN WATCH: any running game a playthrough plays on, each frame shown on
    # +device+ (Live::SDL, a window) and held to the console's frame rate. Nobody's hands are
    # on it, so the window's buttons do nothing but say stop: closing it, or Escape, ends the playing
    # (#step raises WindowClosed). A frame the machine could not play in time is simply late,
    # and the beat starts again from it rather than rushing to catch up.
    #
    # The sound is the emulator's alone. The other ways of running a game keep theirs to the end of
    # the run, or write it to a file, and in a window those play silently.
    class WatchedGame
      # The window was closed, which is how a person stops a playing they were watching.
      class WindowClosed < StandardError; end

      # +sound_rate+ is how many samples a second the game's sound comes at, for each speaker.
      def initialize(game, device, frame_seconds:, sound_rate:)
        @game = game
        @device = device
        @frame_seconds = frame_seconds
        @sound_rate = sound_rate
        @beat = device.now
        @shown = 0
      end

      def step(count = 1, keys: nil)
        count.times do
          @game.step(1, keys: keys)
          show_frame
        end
        self
      end

      def respond_to_missing?(question, include_private = false) = @game.respond_to?(question, include_private) || super

      # Everything else is the game's to answer: this only watches.
      def method_missing(question, ...)
        return super unless @game.respond_to?(question)

        @game.public_send(question, ...)
      end

      private

      def show_frame
        @shown += 1
        @device.show(@game.frame_gba, @game.screen_width, @game.screen_height)
        play_new_sound
        @device.held_buttons(@shown) # the window reads its events here
        @device.hold_while_paused
        raise WindowClosed if @device.stop?

        @beat = [@beat + @frame_seconds, @device.now].max
        @device.wait_until(@beat)
      end

      # The emulator's sound of the frame just played, its two speakers side by side.
      def play_new_sound
        return unless @game.respond_to?(:last_frame_samples)

        left, right = @game.last_frame_samples.each_slice(2).to_a.transpose
        @device.play_sound(left, @sound_rate, right) if left
      end
    end
  end
end
