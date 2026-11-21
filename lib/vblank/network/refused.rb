# frozen_string_literal: true

module VBlank
  module Network
    # A machine that cannot join the match, and the plain words it is told. The host decides, from
    # the game and the console each side is running, and sends the reason; the words are made here,
    # on the machine that was refused, so each lowering can say them in its own place.
    class Refused < StandardError
      REASONS = %i[different_game different_console started full].freeze

      attr_reader :reason

      # Why +mine+, the fingerprint of this machine's game, was not let into a match that is
      # +theirs+. +reason+ is one of reasons.
      def self.because(reason, mine:, theirs:)
        new(reason, words(reason, mine, theirs))
      end

      def self.words(reason, mine, theirs)
        case reason
        when :different_console
          "This match is for the #{console_title(theirs)}, and your game is built for the #{console_title(mine)}. " \
            "To fix this, build your game for the #{console_title(theirs)}."
        when :different_game
          "This match is a different game. The host plays #{theirs.title}, and you have #{mine.title}. " \
            "To fix this, use the same game file and the same build as the host."
        when :started
          "This match has started, and nobody can join it now. To fix this, ask the host to start a new match."
        when :full
          "This match is full. To fix this, ask the host for a place in a new match."
        else
          "The host did not let you into the match (#{reason}). To fix this, ask the host to start a new match."
        end
      end

      # The title of the console +fingerprint+ is built for. The library's own description says it;
      # where the library is not loaded (the window's process, Live::MatchPlay) the titles it was
      # handed do (#console_titles=), and a console named in neither is said by its name.
      def self.console_title(fingerprint)
        name = fingerprint.console.to_s
        return Console.described(name.to_sym).title if defined?(Console.described)

        (@console_titles || {}).fetch(name, name)
      end

      class << self
        # The consoles' titles, by name, for a process that has no Console (#console_title). Set once,
        # on the main Ractor, before a match starts.
        attr_writer :console_titles
      end

      def initialize(reason, words)
        @reason = reason
        super(words)
      end
    end
  end
end
