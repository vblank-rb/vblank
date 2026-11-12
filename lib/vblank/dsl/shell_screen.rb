# frozen_string_literal: true

module VBlank
  module DSL
    # A SHELL'S FIRST SCREEN, as a game makes it its own (Builder#shell_screen hands this to the
    # game's block). A shell is the build with none of the original's data in it, and its first
    # screen is what a player sees until their own copy has been read: a title, a line saying what
    # the game needs, and the lines LOAD ROM and SETTINGS. VBlank writes that screen
    # (Original::Shell.menu_program); a game changes how it looks and adds lines of its own:
    #
    #   shell_screen do |first|
    #     font :runes, glyphs: RUNES                  # declared here: this screen is a program of its own
    #     image :sky, width: 240, height: 160, data: SKY
    #     first.font :runes
    #     first.title "ÆON"
    #     first.needs "LOAD YOUR COPY OF ÆON"
    #     first.colors title: :yellow, cursor: :white, ground: :blue
    #     first.picture :sky
    #     first.line "CREDITS", shows: :credits
    #     scene(:credits) { draw_text "MADE BY US", :center, 40, :white, font: :runes }
    #   end
    #
    # ONE WORD FOR ONE THING. The SCREEN is the first screen. A LINE is one row a player can put
    # the cursor on and choose; LOAD ROM and SETTINGS are lines, always there. The TITLE and what
    # the game NEEDS are words above the lines, which cannot be chosen. A line is in one of three
    # states, each a colour: plain (+line+), under the cursor (+cursor+), and chosen (+chosen+).
    # The GROUND is the colour behind everything, and the PICTURE is drawn over it, under the words.
    #
    # WHAT A LINE OF THE GAME'S OWN MAY DO is a short list, since the shell is not the game: it
    # shows a scene written in the block and comes back to the menu when the player presses A, B
    # or Start (+shows:+). Nothing else yet. It cannot ask for the copy, start the game or end the
    # shell: those are LOAD ROM's and the shell's.
    #
    # NOTHING HERE MAY COME FROM THE DATA PACK. The screen shows before the player's copy is read,
    # so the pack holds nothing yet: a slot given to any of these, or to a verb in the block, is
    # refused in plain words (#refuse_pack_slot!).
    class ShellScreen
      # A line of the game's own: its +words+, the scene it +shows+, the line it goes +under+
      # (:load_rom or :settings), and the line of the game that wrote it (+source+).
      Line = Data.define(:words, :shows, :under, :source)

      # The picture behind the words: a declared picture's +name+, and where its top left goes.
      Picture = Data.define(:name, :x, :y)

      # The parts of the screen that have a colour, and the colour of each where a game gives none.
      DEFAULT_COLORS = { title: :white, needs: :gray, line: :gray, cursor: :white, chosen: :yellow, ground: :black }.freeze

      # The lines a game's own line can go under.
      FIXED_LINES = %i[load_rom settings].freeze

      attr_reader :font_name, :title_words, :needs_words, :backdrop, :lines

      def initialize
        @font_name = nil
        @title_words = nil
        @needs_words = nil
        @colors = {}
        @labels = {}
        @backdrop = nil
        @lines = []
      end

      # The font every word on the screen is written in: one declared in the block with `font`.
      def font(name)
        refuse_pack_slot!(name)
        raise ArgumentError, "shell_screen's `font` takes the name of a font, like `font :runes`. Got #{name.inspect}." unless name.is_a?(Symbol)

        @font_name = name
      end

      # The title's own words, in place of the game's title in capitals.
      def title(words) = @title_words = words_given("title", words)

      # The words of the line that says what the game needs, in place of VBlank's.
      def needs(words) = @needs_words = words_given("needs", words)

      # The words of LOAD ROM and of SETTINGS, for a font that lacks their letters or a game in
      # another language. The lines stay, and do what they do.
      def labels(load_rom: nil, settings: nil)
        @labels[:load_rom] = words_given("labels load_rom:", load_rom) unless load_rom.nil?
        @labels[:settings] = words_given("labels settings:", settings) unless settings.nil?
      end

      # The words of the fixed line +which+ (:load_rom or :settings), or nil where the game gave none.
      def label(which) = @labels[which]

      # The colour of each part named: title:, needs:, line:, cursor:, chosen: and ground:.
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
      def color(part) = @colors.fetch(part, DEFAULT_COLORS.fetch(part))

      # One picture behind the words, declared in the block with `image`, its top left at +at+.
      def picture(name, at: [0, 0])
        refuse_pack_slot!(name)
        unless name.is_a?(Symbol) && at.is_a?(Array) && at.length == 2 && at.all?(Integer)
          raise ArgumentError, "shell_screen's `picture` takes the name of a picture and at: a column and a row, like " \
                               "`picture :sky, at: [0, 0]`. Got #{name.inspect}, at: #{at.inspect}."
        end

        @backdrop = Picture.new(name: name, x: at[0], y: at[1])
      end

      # A line of the game's own, which shows the scene +shows+ and comes back. It goes under LOAD
      # ROM unless +under+ is :settings; lines under the same one stay in the order written.
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
      def self.pack_slot_message(name)
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
