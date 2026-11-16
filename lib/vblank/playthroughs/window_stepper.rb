# frozen_string_literal: true

module VBlank
  module Playthroughs
    # A PLAYTHROUGH A PERSON CAN WATCH: any running game a playthrough plays on, stepped through a
    # Live::Session as `vblank run` plays one, so the window does all it does there: the menu,
    # pause, a frame at a time, fast forward, scale, fullscreen, volume. Only where the buttons come
    # from differs. The script presses them, and what the window's keys and gamepads hold is
    # thrown away, so no hand reaches the game and the same seed plays the same run whatever
    # the person watching does. A paused frame steps nothing and asks the script nothing. The
    # keys and gamepads still work the menu, which the window keeps for itself. Closing the window,
    # or Escape, ends the playing (#step raises WindowClosed).
    #
    # The sound is the game's own on the emulator and the computer builds. The interpreter makes
    # none a speaker can play, so it hands the speaker silence, which paces it the same.
    #
    # THE FRAME RATE SHOWS HOW OFTEN THE GAME MAKES A NEW PICTURE. The emulator is stepped a screen
    # refresh at a time, sixty a second whatever the game does, and a game whose pass takes two
    # frames shows the same picture for two of them. So each refresh that finished no pass of the
    # game is told to the device as a repeat (+repeating_picture=+, the one thing asked of a device
    # here that a Session does not ask), and a window leaves it out of its count. The other ways
    # play a pass a step and never repeat, and a cartridge that cannot report its passes (one built
    # elsewhere, or one that waits for the screen in places of its own on a console that counts the
    # waits) reads as the refresh rate.
    #
    # It only steps: everything a playing asks is asked of the game.
    class WindowStepper
      # The window was closed, which is how a person stops a playing they were watching.
      class WindowClosed < StandardError; end

      # What a Session asks of a game.
      attr_reader :frame_seconds, :sound_rate

      def width = @game.screen_width
      def height = @game.screen_height

      # The script presses every button, so the window seats no players, 0 as for a game that
      # names none (Live::Seats.several_players?): its gamepads only work the menu.
      def seats = 0

      # +sound_rate+ is how many samples a second the game's sound comes at, for each speaker.
      def initialize(game, device, frame_seconds:, sound_rate:)
        require_relative "../live" # not part of `require "vblank"`, and a window is what wants it
        @game = game
        @frame_seconds = frame_seconds
        @sound_rate = sound_rate
        @silence = Array.new((sound_rate * frame_seconds).round, 0)
        @device = device
        @passes_seen = 0
        @session = Live::Session.new(game: self)
        @session.begin_play(device)
      end

      def step(count = 1, keys: nil)
        count.times do
          @game.step(1, keys: keys)
          @device.repeating_picture = no_pass_finished?
          left, right = sound_of_frame
          raise WindowClosed unless @session.buttons_after(@game.frame_gba, left, right)
        end
        self
      end

      private

      # Did the step just played finish no pass of the game loop? Always false for a game that plays
      # a pass a step, or cannot report them.
      def no_pass_finished?
        return false unless @game.respond_to?(:passes)

        passes = passes_so_far or return false
        (passes == @passes_seen).tap { @passes_seen = passes }
      end

      # How many passes the game has finished, or nil where it cannot report it.
      def passes_so_far
        @game.passes
      rescue ArgumentError
        nil
      end

      # The two speakers' sound of the frame just played, or silence.
      def sound_of_frame
        return [@silence, @silence] unless @game.respond_to?(:last_frame_samples)

        left, right = @game.last_frame_samples.each_slice(2).to_a.transpose
        left ? [left, right] : [@silence, @silence]
      end
    end
  end
end
