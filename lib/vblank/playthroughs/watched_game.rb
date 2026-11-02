# frozen_string_literal: true

module VBlank
  module Playthroughs
    # A PLAYTHROUGH A PERSON CAN WATCH: any running game a playthrough plays on, played through a
    # Live::Session as `vblank run` plays one, so the window does all it does there: the menu,
    # pause, a frame at a time, fast forward, scale, fullscreen, volume. Only where the buttons come
    # from differs. The script presses them, and what the window's keys and gamepads hold is
    # thrown away, so no hand reaches the game and the same seed plays the same run whatever
    # the person watching does. A paused frame steps nothing and asks the script nothing. The
    # keys and gamepads still work the menu, which the window keeps for itself. Closing the window,
    # or Escape, ends the playing (#step raises WindowClosed).
    #
    # The sound is the emulator's alone. The other ways of running a game keep theirs to the end of
    # the run, or write it to a file, so they hand the speaker silence, which paces them the same.
    class WatchedGame
      # The window was closed, which is how a person stops a playing they were watching.
      class WindowClosed < StandardError; end

      # What a Session asks of a game.
      attr_reader :frame_seconds, :sound_rate

      def width = @game.screen_width
      def height = @game.screen_height

      # +sound_rate+ is how many samples a second the game's sound comes at, for each speaker.
      def initialize(game, device, frame_seconds:, sound_rate:)
        require_relative "../live" # not part of `require "vblank"`, and a window is what wants it
        @game = game
        @frame_seconds = frame_seconds
        @sound_rate = sound_rate
        @silence = Array.new((sound_rate * frame_seconds).round, 0)
        @session = Live::Session.new(game: self)
        @session.begin_play(device)
      end

      def step(count = 1, keys: nil)
        count.times do
          @game.step(1, keys: keys)
          left, right = sound_of_frame
          raise WindowClosed unless @session.buttons_after(@game.frame_gba, left, right)
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

      # The two speakers' sound of the frame just played: the emulator's, or silence.
      def sound_of_frame
        return [@silence, @silence] unless @game.respond_to?(:last_frame_samples)

        left, right = @game.last_frame_samples.each_slice(2).to_a.transpose
        left ? [left, right] : [@silence, @silence]
      end
    end
  end
end
