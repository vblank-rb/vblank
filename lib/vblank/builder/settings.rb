# frozen_string_literal: true

module VBlank
  class Builder
    # What a game is told when it is built
    #
    # A game that comes in several cuts, such as which floors are in it, where the player starts
    # or which screen it boots on, asks for a setting. A setting is handed to one build and to
    # nothing else. It is a plain Ruby value while the game is built, like the numbers a game
    # works its tables out from, and not a variable the game keeps while it runs.
    #
    # ```ruby
    # floors = setting :floors, 60
    # ```
    #
    # `built_for?` and `built_for_computer?` answer which machine the game is being built for.
    #--
    # A game used to find these out by reading the environment from inside its own block. That is
    # the whole process's, so a test that built a one-floor cartridge changed what every other
    # build running beside it at that moment saw.
    #++
    module Settings
      # Asks whether this build plays on a computer, rather than on a console from a cartridge.
      #
      # The answer is a Ruby true or false while the game is built, as a setting is. Use it for
      # something that costs a cartridge frames and costs a computer nothing. A computer build
      # runs as C, in a web page or as Ruby.
      #
      # ```ruby
      # music = var :music, built_for_computer? ? 1 : 0
      # ```
      def built_for_computer? = @for_computer

      # Asks whether this build is for a console, and for one chip variant of it if you name one.
      #
      # The answer is a Ruby true or false while the game is built, for a choice of what the
      # cartridge holds, such as a song left out of one console's or a title line that only a
      # bigger screen has room for.
      #
      # ```ruby
      # song(:theme) { ... } unless built_for?(:snes)
      # draw_text "DELUXE", 8, 8, :white if built_for?(:snes, variant: :superfx)
      # ```
      #
      # The answer is the console the game is built for, however it is then played. The game as C,
      # in a web page or as Ruby, built for the Advance, answers for the Advance, as its
      # cartridge does, so all of them play the same game.
      #
      # Asking about a console that the game's `consoles:` does not name is an error, since no
      # build of the game could ever answer yes. It is almost always a misspelt name or a console
      # that was not added.
      #
      # * `console` - the console's name, as a symbol.
      # * `variant:` - a chip variant of that console, such as `:superfx`. Left out, it asks about
      #   the console whatever chip its cartridge has. `variant: :none` asks about the plain console.
      def built_for?(console, variant: nil)
        kit = Console.for(console)
        refuse_console_not_for_game!(kit)
        # Read on every build, so a variant the console lacks is refused on the builds for other
        # consoles too, not only on the one build that would have read it.
        asked_variant = kit.variant(variant)&.name unless variant.nil?
        return false unless kit.name == @build_options.console

        variant.nil? || asked_variant == @build_options.variant
      end

      # Gives the value this build was given for a setting, or the default when it was given none.
      #
      # A setting given as text, which is all a command line can give, is read as the kind of
      # thing its default is. `--set floors=1` means the number 1 to a game whose default is 60.
      # A setting with no default has no kind of thing to be read as, so it comes to the game
      # exactly as it was given, and a build that does not give it is an error.
      #
      # ```ruby
      # floors = setting :floors, 60
      # ```
      #
      # * `name` - the setting's name, as a symbol.
      # * `default` - what the game gets when nobody sets one.
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
