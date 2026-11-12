# frozen_string_literal: true

module VBlank
  class Builder
    # A SHELL'S FIRST SCREEN, MADE THE GAME'S OWN. A port built as a shell holds none of the
    # original's data, and until the player's copy has been read it shows a first screen VBlank
    # writes: a title, a line saying what the game needs, LOAD ROM and SETTINGS
    # (Original::Shell.menu_program). `shell_screen` is where a game says how that screen looks
    # and what other lines it has (DSL::ShellScreen has the words and the worked example).
    #
    # THE BLOCK IS A PROGRAM OF ITS OWN, and that is the whole rule. The first screen plays
    # before the game exists as far as the player's machine can tell: the game's program cannot
    # start without its data pack. So the block is not run here, as the game is built. It is
    # kept (#declared_shell_screen), and a shell build runs it on the builder that makes the
    # first screen, as game code, the way a data pack's unpacking routine is run on a builder of
    # its own. A font, a picture or a scene the screen uses is declared INSIDE the block, with the
    # verbs a game declares them with; one declared outside it belongs to the game's program and
    # is not there. A cartridge build never runs the block and holds nothing of it.
    #
    # What follows from that: a mistake in the block is told when the game is built as a shell,
    # not when its cartridge is, and nothing in the block may read the data pack, which is empty
    # until the copy is read.
    module ShellScreens
      # What a game gave for its shell's first screen: the block, and the line that wrote it.
      DeclaredShellScreen = Data.define(:block, :source)

      # Rows between one line and the next, and between the words saying what the game needs and
      # the title above them, besides the font's own height. With the built-in font these put
      # every word where the screen had it before a game could change it.
      LINE_GAP = 5
      TITLE_GAP = 9

      # Make the shell's first screen the game's own. The block is handed a DSL::ShellScreen and
      # is run only when the game is built as a shell, on that screen's own program.
      def shell_screen(&block)
        unless block
          raise ArgumentError, "shell_screen needs a block: `shell_screen do |first| first.title \"...\" end`."
        end
        unless @shell_screen.nil?
          raise ArgumentError, "The game says `shell_screen` twice. A shell has one first screen. Put all of it in one block."
        end

        @shell_screen = DeclaredShellScreen.new(block: block, source: Messages::AuthorSource.author_file_and_line)
        nil
      end

      # What the game gave for its shell's first screen (a DeclaredShellScreen), or nil: what a
      # shell build asks of the game (Original::Shell).
      def declared_shell_screen = @shell_screen

      private

      # THE LOOK OF THE FIRST SCREEN THIS BUILDER IS MAKING (an Original::Shell::Look): what
      # +declared+ gave, its block run here as game code, and the screen's own for the rest.
      # +title+ is the game's title. With nothing declared it is the screen as it always was.
      def shell_screen_look(title, declared)
        given = DSL::ShellScreen.new
        if declared
          @shell_first_screen = true # a data pack slot is refused from here on (#refuse_slot_on_first_screen!)
          instance_exec(given, &declared.block)
        end
        font = given.font_name || :default
        look = Original::Shell::Look.new(font: font, title: shell_screen_title(title, given, font),
                                         needs: given.needs_words || Original::Shell::MENU_NEEDS,
                                         colors: DSL::ShellScreen::DEFAULT_COLORS.to_h { |part, _| [part, given.color(part)] },
                                         picture: given.backdrop, lines: Original::Shell.menu_lines(given))
        refuse_unusable_shell_screen!(look, declared) if declared
        look
      end

      # The title's words: the game's own, or the game's title, in capitals with the letters the
      # built-in font lacks left out where the screen is written in that font.
      def shell_screen_title(title, given, font)
        return given.title_words if given.title_words
        return title.to_s unless font == :default

        title.to_s.upcase.gsub(Original::Shell::MENU_LETTERS, "").strip
      end

      # The row the title, the words saying what the game needs, and the line at +place+ are each
      # written on, in a font +height+ rows tall: the lines from the screen's middle down, the
      # other two above it.
      def shell_screen_rows(height)
        middle = screen_height / 2
        step = height + LINE_GAP
        needs = middle - (2 * step)
        Original::Shell::Rows.new(title: needs - (height + TITLE_GAP), needs: needs, first_line: middle, step: step)
      end

      # Everything a game can get wrong on its first screen that only shows once the whole block
      # has run, each told naming the block's line.
      def refuse_unusable_shell_screen!(look, declared)
        where = "shell_screen (#{declared.source})"
        refuse_shell_screen_font_of_pictures!(look.font, where)
        font = IR::FontTable.of(@program).get(look.font)
        words = [look.title, look.needs, *look.lines.map(&:words)]
        words.each { |each_words| refuse_shell_screen_words!(each_words, font, look.font, where) }
        refuse_shell_screen_not_fitting!(look, font, where)
        if look.picture && !@images.key?(look.picture.name)
          raise ArgumentError, "#{where} shows the picture :#{look.picture.name}, and the block declares no such picture. " \
                               "To fix this, declare it in the block with `image :#{look.picture.name}, ...`."
        end
        look.lines.each { |line| refuse_shell_screen_line_without_scene!(line, where) }
      end

      def refuse_shell_screen_font_of_pictures!(name, where)
        return unless picture_font?(name) || lettering_font?(name)

        raise ArgumentError, "#{where} is written in font :#{name}, which is made of pictures. A line changes color when " \
                             "the cursor is on it, and pictures have their own colors. To fix this, use a font of glyphs " \
                             "(`font :name do glyph ... end` or `font :name, glyphs: ...`)."
      end

      def refuse_shell_screen_words!(words, font, font_name, where)
        missing = font.missing_characters(words)
        unless missing.empty?
          raise ArgumentError, "#{where} writes #{words.inspect} in font :#{font_name}, and the font has no " \
                               "#{missing.map(&:inspect).join(', ')}. To fix this, give the font these characters, or give " \
                               "the screen other words with `title`, `needs`, `labels` or `line`."
        end
        return if font.text_width(words) <= screen_width

        raise ArgumentError, "#{where} writes #{words.inspect}, which is #{font.text_width(words)} pixels wide in font " \
                             ":#{font_name}. The screen is #{screen_width} pixels wide. To fix this, use fewer words."
      end

      def refuse_shell_screen_not_fitting!(look, font, where)
        rows = shell_screen_rows(font.height)
        most = ((screen_height - rows.first_line - font.height) / rows.step) + 1
        if look.lines.length > most
          raise ArgumentError, "#{where} has #{look.lines.length} lines, and #{most} lines fit the screen in font " \
                               ":#{look.font}. To fix this, remove #{look.lines.length - most} of the game's own lines, or " \
                               "use a font with less height."
        end
        return unless rows.title.negative?

        raise ArgumentError, "#{where} is written in font :#{look.font}, which is #{font.height} rows tall. The title does " \
                             "not fit above the lines. To fix this, use a font with less height."
      end

      def refuse_shell_screen_line_without_scene!(line, where)
        return if line.scene.nil? || @functions.key?(:"_scene_#{line.scene}")

        raise ArgumentError, "#{where}: the line #{line.words.inspect} (#{line.source}) shows the scene :#{line.scene}, and " \
                             "the block has no such scene. To fix this, write it in the block: `scene(:#{line.scene}) { ... }`."
      end

      # A data pack slot handed to a verb on the first screen's builder, refused in the screen's
      # own words (Builder::DataPacks#refuse_slot_from_elsewhere! asks).
      def refuse_slot_on_first_screen!(handle)
        raise ArgumentError, DSL::ShellScreen.pack_slot_message(handle.layout.name) if @shell_first_screen
      end
    end
  end
end
