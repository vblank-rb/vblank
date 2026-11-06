# frozen_string_literal: true

module VBlank
  # Declares a bot: `VBlank.bot "chaser", plays: "wanderers.rb" do |game| ... end`. +plays+ is the game file the
  # bot plays, found beside the bot's own file. The block is asked once a pass and answers the buttons to hold.
  def self.bot(name, plays: nil, &decide) = Bots::Bot.define(name, plays: plays, &decide)

  module Bots
    # A BOT: a name, the game it plays, and a block that is handed a view of the game (GameView) once a pass
    # and answers which buttons its player holds. The answer is an Array of button names (`[:left, :up]`),
    # one name, or nil or `[]` for nothing. The names are the plain ones: a bot has one player, and the match
    # knows which.
    #
    # WHEN THE BUTTONS ARE USED. The bot looks at the game at the end of pass p, and what it answers is used
    # by pass p + 1 + the match's input delay, on every machine at once. A bot that chases is a little behind
    # the one it chases, as a person is.
    class Bot
      # The bots a file made while it was being loaded, in order, or nil when nothing is collecting.
      COLLECTING_KEY = :vblank_bots_being_collected

      attr_reader :name, :plays

      # Makes a bot, and keeps it for #collecting when a file is being loaded.
      def self.define(name, plays: nil, &decide)
        raise ArgumentError, "A bot needs a block that chooses its buttons: `VBlank.bot \"name\" do |game| ... end`." unless decide

        new(name, plays, decide).tap { |bot| Thread.current[COLLECTING_KEY]&.push(bot) }
      end

      # Runs the block, and gives back the bots it made with `VBlank.bot`.
      def self.collecting
        outer = Thread.current[COLLECTING_KEY]
        made = Thread.current[COLLECTING_KEY] = []
        yield
        made
      ensure
        Thread.current[COLLECTING_KEY] = outer
      end

      def initialize(name, plays, decide)
        @name = name.to_s
        @plays = plays
        @decide = decide
      end

      # The buttons to hold, as a list of names, for what +view+ shows. A name that is not a button of this
      # player is a friendly error.
      def buttons_for(view)
        names = Buttons.names_in(@decide.call(view))
        Buttons.refuse_unknown_buttons!(names, who: "The bot #{name.inspect}")
        names
      end

      # What answers a bot can give, read and checked in one place for every kind of bot.
      module Buttons
        module_function

        # The button names in a bot's +answer+: an Array of names, one name, or nil for none.
        def names_in(answer) = Array(answer).compact

        # Raises a friendly ArgumentError when one of +names+ is not a button of a player. +who+ begins the words.
        def refuse_unknown_buttons!(names, who:)
          unknown = names.find { |button| !IR::Buttons.known?(button) } or return

          raise ArgumentError, "#{who} answered #{unknown.inspect}, which is not a button. A bot's player is the " \
                               "one the match gave it, so answer the plain names: #{IR::Buttons::NAMES.map(&:inspect).join(', ')}."
        end
      end
    end
  end
end
