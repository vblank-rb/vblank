# frozen_string_literal: true

module VBlank
  module Live
    # A DEVICE FOR A PLAYER WITH NO WINDOW AND NO PERSON (Bots): it shows nothing, plays no sound, and asks a
    # bot which buttons to hold. The session hands it the game it runs (#watch), so the bot can read it, and
    # asks it once a pass for the buttons held (#held_buttons), which is when the bot looks at the game.
    #
    # ITS CLOCK MOVES ONLY WHEN SOMETHING SAYS IT DOES, so it never waits for real time: a bot plays as fast as
    # the other machines let it, and in a match that is as fast as the slowest of them, since every
    # machine waits for every other's buttons.
    #
    # The play ends after +passes+ passes if that is given, when the bot says it is done (#stop? asks it),
    # or when the match or the game does. +keep_picture+ keeps the last picture, for a test to look at.
    class BotDevice
      attr_reader :view, :last_picture, :notices

      def initialize(bot, passes: nil, keep_picture: false, on_notice: nil)
        @bot = bot
        @passes = passes
        @keep_picture = keep_picture
        @on_notice = on_notice
        @notices = []
        @now = 0r
        @shown = 0
      end

      # The session says which game this device is playing, and how the match is set up, before the first pass.
      def watch(game, player:, players:, input_delay:)
        @view = Bots::GameView.new(game, player: player, players: players, input_delay: input_delay)
      end

      def show(pixels, width, height)
        @shown += 1
        @last_picture = Picture.new(pixels: pixels.dup, width: width, height: height) if @keep_picture
      end

      Picture = Headless::Picture

      def play_sound(_left, _rate, _right = nil); end
      def sound_waiting = nil
      def fast_forward_speed(_pass) = 1
      def hold_while_paused = false
      def stop? = !@passes.nil? && @shown >= @passes

      # What the bot holds, looking at the game as pass +pass+ has ended.
      def held_buttons(pass) = @bot.buttons_for(@view.reached(pass))

      def notice(words)
        @notices << words
        @on_notice&.call(words)
      end

      attr_reader :now

      def wait_until(seconds) = @now = [@now, seconds.to_r].max
    end
  end
end
