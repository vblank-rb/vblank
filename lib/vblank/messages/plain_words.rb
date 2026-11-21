# frozen_string_literal: true

module VBlank
  module Messages
    # What a person calls this.
    #
    # A build talks: a progress line while it works, a guardrail's warning, a build error, and
    # `rom.profile` at the end. Those four come from corners of the framework that never meet,
    # and every one of them has the same small job somewhere in it — take something the machine
    # knows by an internal name and say it in English.
    #
    # Done where it is needed, that job gets done again in each corner, and the answers drift
    # apart. The console's 32K of fast memory is what that looks like: one name for it in the
    # report, a second in a guardrail's error, a third in the progress line — minutes apart, in
    # one build, read by somebody who is trying to work out what the thing is. A learner cannot
    # tell three names for one thing from three different things.
    #
    # So the English lives here and the corners read it. Two things follow that cannot be had
    # while it is scattered: rewording something is one edit in one place, and a test can fail
    # when a second name for one thing turns up (see test/all/vblank/messages/test_plain_words.rb).
    #
    # What belongs here is a name for a thing several places have to mention — a piece of
    # hardware, a routine nobody wrote, a verb whose node kind is not what the author typed.
    # What does not belong here is the wording of any one message. A guardrail's sentence is
    # written where the guardrail is, next to the code that knows why it fires; only the shared
    # nouns in it come from here.
    module PlainWords
      # The console's 32K of fast memory. Code and data kept there are reached without waiting,
      # where everything in the cartridge is fetched over a narrow connection — the same
      # instructions run about two and a half times faster in one place than the other, which is
      # why the framework brings it up at all. Its hardware name is IWRAM, and a person reading a
      # build has no reason to know that word, so nothing they read says it.
      QUICK_MEMORY = "quick memory"

      # What it must never be called, so a test can fail when one of these turns up in something a
      # build prints. Comments are exempt and deliberately so — a comment teaches the hardware and
      # may name IWRAM outright; this is about what a person running a build reads.
      NOT_CALLED = Ractor.make_shareable(
        { QUICK_MEMORY => [/\bfast RAM\b/i, /\bquick RAM\b/i, /\bfast memory\b/i,
                           /\bIWRAM\b/, /\bfast on-chip\b/i] }
      )

      # The routines the author never wrote. A game loop's body is statements rather than a
      # routine, and nobody types the routine the console jumps into when the display or a timer
      # announces something — but the build treats both as routines, because that is what lets
      # the same choosing and the same report cover them (see Backends::GBA::Placement). So both
      # turn up in a progress line and in `rom.profile`, and both need a name a reader can place.
      # The setting up before the game loop is named the same way, for `rom.profile` alone: it is
      # never placed, but it can be most of a game's first frame.
      #
      # Everything else on those lists is a routine somebody wrote, and its own name is already
      # the best one there is, so it is given back the way they would type it.
      # The last two are not routines either, and nobody chose them: this chip cannot divide, so
      # every division in a program goes through code the build copies in for it. They show up in
      # a measured profile and need a name a reader can act on — a hot one is worth replacing with
      # a table.
      # The symbols are written out rather than reached for, because this file is loaded long
      # before the backend that defines them. A test holds the two lists against each other.
      ROUTINES = { __frame: "the game loop", __setting_up: "setting the game up, before the game loop",
                   __interrupt: "the routine that answers the display and the timers, and plays the music " \
                                "and the sound effects",
                   __divide_routine: "dividing",
                   __divide_fix_routine: "dividing numbers that hold a fraction",
                   __mix_routine: "mixing the sound that is playing",
                   __fill_face_routine: "filling the faces of a place with their pictures",
                   __clock_chip_at_power_on: "asking the cartridge's clock chip whether it is there and set",
                   __clock_chip_each_pass: "reading the date and time off the cartridge's clock chip",
                   __clock_chip_first_reading: "asking the clock chip the time at the first reading of a pass",
                   __clock_chip_set: "setting the clock to the time the game gave",
                   __clock_chip_add_offset: "adding the time the game set to the clock's reading",
                   __clock_chip_send: "sending the clock chip a command",
                   __clock_chip_receive: "reading a byte back from the clock chip" }.freeze

      # Everything else the build made up — a record's save routines, a font's digit routine, a
      # scene's sprite routine — is said in terms of what the author declared, by the table that
      # made the name (see MadeNames). What is left is a routine the author wrote and named.
      def self.routine(name)
        ROUTINES.fetch(name) { MadeNames.words_for_made_name(name) || "func :#{name}" }
      end

      # The verb an author typed, for the few node kinds whose internal name is not that verb. A
      # message naming the kind back at somebody names something they never wrote: nobody types
      # `draw_digit`, they type `draw_number`, and a `blit_pose` is what a `sprite` became.
      VERBS = { blit_pose: "sprite", draw_digit: "draw_number", show_light_now: "light.show_now" }.freeze

      def self.verb(kind) = VERBS.fetch(kind) { kind.to_s }

      # The verb the author wrote for +node+. One kind can stand for more than one verb: a
      # `fill_rect` given a number the game works out is drawn as a `draw_rect_at`, and the node
      # remembers the verb it was written as (IR::Nodes::DrawRectAt#written_as).
      def self.verb_written(node)
        written = node.kind == :draw_rect_at ? node.written_as : nil
        written ? written.to_s : verb(node.kind)
      end

      # How a message names a game's own number. Many verbs take a number that must be
      # written in the program (a beat, a column, a count of digits) and refuse one the game
      # works out as it runs. What they were handed is then a handle, a symbol or a node of the
      # tree, and none of those reads well printed as Ruby prints it: a handle's inspect is a
      # screenful of the builder. So the refusal names the variable the author wrote, and gives
      # "a number that the game works out as it runs" for anything else (an expression, a pool's
      # field, a variable the framework made for itself).
      WORKED_OUT_NUMBER_WORDS = "a number that the game works out as it runs"

      # Is +given+ one of the game's numbers: a handle, or a value node? A handle is known by what
      # it answers rather than by its class, since this loads before the DSL that defines it.
      def self.game_number?(given)
        node = given.respond_to?(:node) ? given.node : given
        node.is_a?(IR::Node) && node.value?
      end

      # How a message names +given+: a game's number as words, and anything else as Ruby writes
      # it, which for a number, a string or a symbol is what the author typed. A variable is named
      # with why it does not fit ("the variable `speed`, which the game works out as it runs"),
      # since the author can see that `speed` holds a number. A list (a place, `at: [x, y]`) is
      # written item by item, and so is a span (`within: 0..width`), so a variable in either is
      # named too.
      def self.words_for_given(given)
        if given.is_a?(Array) && given.any? { |item| game_number?(item) }
          return "[#{given.map { |item| short_words_for(item) }.join(', ')}]"
        end
        if given.is_a?(Range) && [given.begin, given.end].any? { |item| game_number?(item) }
          dots = given.exclude_end? ? "..." : ".."
          return "#{short_words_for(given.begin)}#{dots}#{short_words_for(given.end)}"
        end
        return given.inspect unless game_number?(given)

        worked_out_clause(short_words_for(given))
      end

      # How a message names the variable called +name+, with why it does not fit, as
      # #words_for_given does: for a symbol that names a variable where a number goes.
      def self.words_for_variable(name) = worked_out_clause(variable_words(name))

      # A game's number by its variable's name, or as WORKED_OUT_NUMBER_WORDS; anything else as Ruby
      # writes it.
      def self.short_words_for(given)
        return given.inspect unless game_number?(given)

        name = variable_name_of(given)
        name ? variable_words(name) : WORKED_OUT_NUMBER_WORDS
      end

      # A name the framework made for itself (two underscores first, like a sprite's place) is
      # nothing the author wrote, so it is given as a number the game works out.
      def self.variable_words(name)
        name.to_s.start_with?("__") ? WORKED_OUT_NUMBER_WORDS : "the variable `#{name}`"
      end

      def self.worked_out_clause(words)
        words == WORKED_OUT_NUMBER_WORDS ? words : "#{words}, which the game works out as it runs"
      end

      # The variable a handle or a node reads, or nil for a working-out. A hidden copy the build
      # made for a plain Ruby name is named by that name (DSL::Value#owner_name).
      def self.variable_name_of(given)
        return given.owner_name if given.respond_to?(:owner_name) && given.owner_name

        name = given.name if given.respond_to?(:name) && !given.is_a?(IR::Node)
        node = given.respond_to?(:node) ? given.node : given
        name || (node.name if node.kind == :var_ref)
      end
      private_class_method :short_words_for, :variable_words, :worked_out_clause, :variable_name_of
    end
  end
end
