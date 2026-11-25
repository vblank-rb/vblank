# frozen_string_literal: true

module VBlank
  module DSL
    # A shell's first screen
    #
    # A shell is the build of a port with none of the original's data in it. Its first screen is
    # what a player sees until their own copy of the original has been read: a title, a line that
    # says what the game needs, and the lines to load the copy and to open the settings. VBlank
    # writes that screen, and `shell_screen` hands it to the game's block so the game can change
    # how it looks and add lines of its own.
    #
    # ```ruby
    # shell_screen do |first|
    #   font :runes, glyphs: RUNES        # declared here: this screen is a program of its own
    #   image :sky, width: 240, height: 160, data: sky
    #   first.font :runes
    #   first.title "AEON"
    #   first.needs "load your copy of AEON"
    #   first.colors title: :yellow, cursor: :white, ground: :blue
    #   first.picture :sky
    #   first.line "credits", shows: :credits
    #   scene(:credits) { draw_text "made by us", :center, 40, :white, font: :runes }
    # end
    # ```
    #
    # ### The words this page uses
    #
    # The screen is the first screen. A line is one row a player can put the cursor on and choose.
    # The line that loads the copy and the settings line are always there. The title and what the
    # game needs are words above the lines, which cannot be chosen. A line is in one of three
    # states, each a colour: plain (`line:`), under the cursor (`cursor:`), and chosen (`chosen:`).
    # The ground is the colour behind everything, and the picture is drawn over it, under the
    # words.
    #
    # ### What a line of the game's own can do
    #
    # It shows a scene written in the block, and comes back to the menu when the player presses A,
    # B or Start. It cannot ask for the copy, start the game or end the shell: those belong to the
    # line that loads the copy, and to the shell.
    #
    # Nothing here can come from the data pack. The screen shows before the player's copy is read,
    # so the pack holds nothing yet, and a slot given to any of these, or to a verb in the block, is
    # refused in plain words.
    #--
    # VBlank's own screen is Original::Shell.menu_program; this is what it reads the game's changes
    # from. The refusal of a pack slot is #refuse_pack_slot!.
    #++
    class ShellScreen
      # A line of the game's own: its +words+, the scene it +shows+, the line it goes +under+
      # (:load_rom or :settings), and the line of the game that wrote it (+source+).
      Line = Data.define(:words, :shows, :under, :source) # :nodoc:

      # The picture behind the words: a declared picture's +name+, and where its top left goes.
      Picture = Data.define(:name, :x, :y) # :nodoc:

      # The parts of the screen that have a colour, and the colour of each where a game gives none.
      DEFAULT_COLORS = { title: :white, needs: :gray, line: :gray, cursor: :white, chosen: :yellow, ground: :black }.freeze # :nodoc:

      # The lines a game's own line can go under.
      FIXED_LINES = %i[load_rom settings].freeze # :nodoc:

      attr_reader :font_name, :title_words, :needs_words, :backdrop, :lines # :nodoc:

      def initialize
        @font_name = nil
        @title_words = nil
        @needs_words = nil
        @colors = {}
        @labels = {}
        @backdrop = nil
        @lines = []
      end

      # Sets the font every word on the screen is written in.
      #
      # The font is one declared in the block with `font`, since the first screen is a program of
      # its own.
      #
      # ```ruby
      # first.font :runes
      # ```
      def font(name)
        refuse_pack_slot!(name)
        raise ArgumentError, "shell_screen's `font` takes the name of a font, like `font :runes`. Got #{name.inspect}." unless name.is_a?(Symbol)

        @font_name = name
      end

      # Sets the title's words, in place of the game's title in capitals.
      #
      # ```ruby
      # first.title "AEON"
      # ```
      def title(words) = @title_words = words_given("title", words)

      # Sets the words of the line that says what the game needs, in place of VBlank's.
      #
      # ```ruby
      # first.needs "load your copy of AEON"
      # ```
      def needs(words) = @needs_words = words_given("needs", words)

      # Sets the words of the line that loads the copy and of the settings line.
      #
      # This is for a font that lacks their letters, or a game in another language. The lines stay,
      # and do what they do.
      #
      # ```ruby
      # first.labels load_rom: "lade", settings: "optionen"
      # ```
      #
      # * `load_rom:` - the words of the line that loads the copy.
      # * `settings:` - the words of the settings line.
      def labels(load_rom: nil, settings: nil)
        @labels[:load_rom] = words_given("labels load_rom:", load_rom) unless load_rom.nil?
        @labels[:settings] = words_given("labels settings:", settings) unless settings.nil?
      end

      # The words of the fixed line +which+ (:load_rom or :settings), or nil where the game gave none.
      def label(which) = @labels[which] # :nodoc:

      # Sets the colour of each part of the screen named.
      #
      # ```ruby
      # first.colors title: :yellow, cursor: :white, ground: :blue
      # ```
      #
      # * `title:` - the title. White to start with.
      # * `needs:` - the words that say what the game needs. Gray to start with.
      # * `line:` - a line not under the cursor. Gray to start with.
      # * `cursor:` - the line under the cursor. White to start with.
      # * `chosen:` - the line just chosen. Yellow to start with.
      # * `ground:` - the colour behind everything. Black to start with.
      def colors(**parts)
        unknown = parts.keys - DEFAULT_COLORS.keys
        unless unknown.empty?
          raise ArgumentError, "shell_screen's `colors` was given #{unknown.map { |part| "#{part}:" }.join(', ')}. The parts " \
                               "of the first screen are #{DEFAULT_COLORS.keys.map { |part| "#{part}:" }.join(', ')}. Use those names."
        end

        parts.each_value { |color| refuse_pack_slot!(color) }
        @colors.merge!(parts)
      end

      # The colour of +part+: the game's, or the screen's own.
      def color(part) = @colors.fetch(part, DEFAULT_COLORS.fetch(part)) # :nodoc:

      # Puts one picture behind the words.
      #
      # The picture is one declared in the block with `image`.
      #
      # ```ruby
      # first.picture :sky, at: [0, 0]
      # ```
      #
      # * `at:` - where its top left goes: a column and a row, in pixels.
      def picture(name, at: [0, 0])
        refuse_pack_slot!(name)
        unless name.is_a?(Symbol) && at.is_a?(Array) && at.length == 2 && at.all?(Integer)
          raise ArgumentError, "shell_screen's `picture` takes the name of a picture and at: a column and a row, like " \
                               "`picture :sky, at: [0, 0]`. Got #{name.inspect}, at: #{at.inspect}."
        end

        @backdrop = Picture.new(name: name, x: at[0], y: at[1])
      end

      # Adds a line of the game's own, which shows a scene and comes back to the menu.
      #
      # Lines under the same fixed line stay in the order written.
      #
      # ```ruby
      # first.line "credits", shows: :credits
      # first.line "help", shows: :help, under: :settings
      # ```
      #
      # * `shows:` - the name of a scene written in the block.
      # * `under:` - the fixed line it goes under: `:load_rom` (the line that loads the copy) or
      #   `:settings`.
      def line(words, shows: nil, under: :load_rom)
        words = words_given("line", words)
        refuse_pack_slot!(shows)
        unless shows.is_a?(Symbol)
          raise ArgumentError, "shell_screen's line #{words.inspect} needs shows:, the name of a scene written in the " \
                               "block, like `line #{words.inspect}, shows: :credits`. A line of the game's own can show a " \
                               "scene and come back. It can do nothing else."
        end
        unless FIXED_LINES.include?(under)
          raise ArgumentError, "shell_screen's line #{words.inspect} was given under: #{under.inspect}. A line goes under " \
                               ":load_rom or under :settings. Use one of those."
        end

        @lines << Line.new(words: words, shows: shows, under: under, source: Messages::AuthorSource.author_file_and_line)
      end

      # Why nothing of the data pack can be on the first screen, for the slot called +name+.
      def self.pack_slot_message(name) # :nodoc:
        "The shell's first screen was given slot :#{name} of the data pack. This screen shows before the player's copy " \
          "is read, so the data pack holds nothing then. To fix this, give the screen a font, pictures and colors of the " \
          "game's own."
      end

      private

      # Refuses +given+ when it is a handle on the data pack, in the words every part of the first
      # screen refuses one in.
      def refuse_pack_slot!(given)
        slot = given.respond_to?(:slot) ? given.slot : given
        raise ArgumentError, ShellScreen.pack_slot_message(slot.layout.name) if slot.is_a?(PackSlot)
      end

      def words_given(what, words)
        refuse_pack_slot!(words)
        return words if words.is_a?(String)

        raise ArgumentError, "shell_screen's `#{what}` takes words, like `#{what} \"...\"`. Got #{words.inspect}."
      end
    end
  end
end
