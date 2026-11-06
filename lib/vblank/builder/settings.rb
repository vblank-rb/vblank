# frozen_string_literal: true

module VBlank
  class Builder
    # WHAT A GAME IS TOLD WHEN IT IS BUILT. A game that comes in several cuts — which floors
    # are in it, where the player starts, which screen it boots on — used to find out by
    # reading the environment from inside its own block. That is the whole process's, so a
    # test that built a one-floor cartridge changed what every other build running beside it
    # at that moment saw. A setting is handed to this one build and to nothing else.
    #
    #   floors = setting :floors, 60
    #
    # The line is the whole of it: the name, and what the game gets when nobody sets one. It is
    # a value while the game is BUILT — a Ruby value, like the numbers a game computes its
    # tables from — not a variable the game keeps while it runs.
    module Settings
      # WHETHER THIS BUILD PLAYS ON A COMPUTER, as C, in a web page or as Ruby, rather than on a
      # console from a cartridge: a Ruby true or false while the game is built, as a setting is,
      # for something that costs a cartridge frames and costs a computer nothing.
      #
      #   music = var :music, built_for_computer? ? 1 : 0
      def built_for_computer? = @for_computer

      # WHETHER THIS BUILD IS FOR +console+ (and, given one, its +variant+): a Ruby true or false
      # while the game is built, as built_for_computer? is, for a choice of what the cartridge
      # holds — a song left out of one console's, a title line only a bigger screen has room for.
      #
      #   song(:theme) { ... } unless built_for?(:snes)
      #   draw_text "DELUXE", 8, 8, :white if built_for?(:snes, variant: :superfx)
      #
      # The answer is the console the game is BUILT for, whichever way it is then played: the
      # game as C, in a web page or as Ruby, built for the Advance, answers for the Advance, as
      # its cartridge does, so all of them play the same game. +variant+ left out asks about the
      # console whatever chip its cartridge has; `variant: :none` asks about the plain console.
      #
      # Asking about a console the game's `consoles:` does not name is refused, since no build of
      # the game could ever answer yes: it is almost always a misspelt name or a console not added.
      # That refusal is why this `?` can raise, as `held(:jump)` does for a button there is none
      # of: a question asked wrongly is the game's mistake, and false would hide it.
      def built_for?(console, variant: nil)
        kit = Console.for(console)
        refuse_console_not_for_game!(kit)
        # Read on every build, so a variant the console lacks is refused on the builds for other
        # consoles too, not only on the one build that would have read it.
        asked_variant = kit.variant(variant)&.name unless variant.nil?
        return false unless kit.name == @build_options.console

        variant.nil? || asked_variant == @build_options.variant
      end

      # The value this build was given for +name+, or +default+ when it was given none. With
      # no default the setting has to be given.
      #
      # A setting given as TEXT — which is all a command line can give — is read as the kind
      # of thing its default is, so `--set floors=1` means the number 1 to a game whose
      # default is 60. A setting with no default has no kind of thing to be read as, so it
      # comes to the game exactly as it was given.
      def setting(name, default = NO_DEFAULT)
        name = name.to_sym
        @asked_settings << name
        return read_setting(name, @settings.fetch(name), default) if @settings.key?(name)
        return default unless default.equal?(NO_DEFAULT)

        raise ArgumentError, "The setting :#{name} has no default, and this build did not give it. " \
                             "#{given_settings_sentence}To fix this, give it when you build, for example " \
                             "`settings: { #{name}: ... }` or `--set #{name}=...`, or give it a default: " \
                             "`setting :#{name}, <default>`."
      end

      NO_DEFAULT = Object.new.freeze

      private

      def refuse_console_not_for_game!(kit)
        consoles = @build_options.game_consoles
        if consoles.empty?
          raise ArgumentError, "The game asks `built_for?(:#{kit.name})`, and this build names no console. " \
                               "To fix this, name the console when you build, for example `console: :gba`."
        end
        return if consoles.include?(kit.name)

        raise ArgumentError, "The game asks `built_for?(:#{kit.name})`. :#{kit.name} is not one of the consoles " \
                             "the game is for (#{consoles.map { |name| ":#{name}" }.join(', ')}), so the answer " \
                             "is always false. To fix this, ask about one of those consoles, or add the " \
                             "#{kit.title} where the game is named: `consoles: %i[#{(consoles + [kit.name]).join(' ')}]`."
      end

      # The names this build gave, when there are any — a missing setting is most often one
      # given under another spelling.
      def given_settings_sentence
        return "" if @settings.empty?

        "This build gave #{@settings.keys.map { |n| ":#{n}" }.join(', ')}. "
      end

      # A setting the build was given that the game never asked for is almost always a name
      # spelled two ways, and the build would otherwise go ahead with the default and look
      # right. Asked once the block has run, because only then is every question in (see
      # Builder#check_settings_were_asked!).
      def unasked_setting_error
        unasked = @settings.keys - @asked_settings.to_a
        return nil if unasked.empty?

        name = unasked.first
        asked = @asked_settings.map { |n| ":#{n}" }.join(", ")
        asked = asked.empty? ? "It asks for no settings." : "It asks for #{asked}."
        "This build gave the setting :#{name}, and the game does not ask for it. #{asked} " \
          "To fix this, use one of those names, or ask for it with `setting :#{name}, <default>`."
      end

      def read_setting(name, given, default)
        return given unless given.is_a?(String) && !default.equal?(NO_DEFAULT) && !default.is_a?(String)

        case default
        when Integer then Integer(given, 10)
        when Float then Float(given)
        when Symbol then given.to_sym
        when true, false then { "true" => true, "false" => false }.fetch(given)
        else given
        end
      rescue ArgumentError, KeyError
        raise ArgumentError, "The setting :#{name} was given #{given.inspect}, and its default is " \
                             "#{default.inspect}. To fix this, give it the same kind of value as its default."
      end
    end
  end
end
