# frozen_string_literal: true

module VBlank
  class Builder
    # Text on the screen
    #
    # `draw_text` writes words, such as labels and dialogue, and `draw_number` writes a number that
    # changes as the game runs, such as a score or a damage counter. They are separate because a
    # game uses them differently. `font` makes a font of your own, and `text_width` and
    # `text_height` measure what will be drawn, to size a box round it.
    #
    # ```ruby picture=still
    # VBlank.game "TEXT", consoles: %i[gba] do
    #   screen :tiled, backdrop: rgb(3, 4, 7)
    #   score = 0
    #   draw_text "SCORE", 84, 68, :white
    #   # shows the score as it changes
    #   draw_number score, 120, 68, :yellow,
    #                               digits: 5
    #   draw_text "HELLO FROM VBLANK", 70, 84,
    #                                  :cyan
    #   game_loop do
    #     score += 7
    #   end
    # end
    # ```
    #
    # ```ruby
    # draw_text "SCORE", 8, 8, :white
    # draw_number score, 56, 8, :white, digits: 5
    # ```
    #--
    # Built on the same 5x7 bitmap font; the only thing the two share is the font that renders a
    # glyph. A concern of Builder, mixed in flat.
    #++
    module Text
      # The font advances this many pixels per character (a 5px glyph + a 1px gap).
      GLYPH_WIDTH = 6  # :nodoc:

      # How many digit columns draw_number reserves when you don't give one. A live
      # number's width isn't known until the game runs, so it draws in a fixed field.
      DEFAULT_DIGITS = 4  # :nodoc:

      # The screen modes with no framebuffer to paint into — text on either of these
      # is drawn as little hardware-sprite glyphs (see #draw_text_tiled), not written
      # into pixels. `screen :rotozoom` is tile hardware too (see IR::Modes::AFFINE):
      # a different pair of background layers from `screen :tiled`'s four, but the
      # same sprite hardware composites glyphs over it exactly the same way.
      TILE_HARDWARE_MODES = %i[tiled rotozoom].freeze  # :nodoc:

      # Where a line of text sits, named instead of counted. These go where the left
      # edge goes, so `draw_text "PONG", :center, 40, :white` centres it.
      #
      # A number is still right when you actually want a number. What a number cannot
      # be is CENTRED: a proportional font has no per-character width to multiply by,
      # so the only thing that knows how wide "PRESS START" comes out is the font
      # itself. Ask it, and a label can be reworded without a stale number left behind.
      ALIGNMENTS = %i[left center right].freeze  # :nodoc:

      # Defines a font, so that `draw_text` can pick it with `font:`, and returns its name.
      #
      # A font can be drawn as little pictures of glyphs, the way `image` defines a picture from
      # text art. Inside the block, `glyph` gives a character its art. A lit pixel is the `on:`
      # character, which is `"#"` by default, and anything else is blank. Glyphs share one height
      # but can differ in width, so a narrow "I" beside a wide "M" is drawn proportionally and not
      # on a fixed grid.
      #
      # ```ruby
      # font :heavy do
      #   glyph "A", <<~ART
      #     ###
      #     # #
      #     ###
      #   ART
      # end
      # draw_text "A", 10, 10, :white, font: :heavy   # define with `font`, select with `font:`
      # ```
      #
      # That suits a font you are inventing. For a font that already exists, give the glyphs as
      # pictures: `glyphs:` maps each character to rows of pixel values, and a pixel that is not
      # `blank:` is lit. Each glyph keeps its own width, so an alphabet that was drawn
      # proportionally stays proportional. Give a block or `glyphs:`, not both.
      #
      # ```ruby
      # font :imported, glyphs: { "A" => [[0, 1, 0], [1, 1, 1]] }
      # font :lettering, glyphs: { "A" => pack[:font].pixels(0, 70) }, height: 10
      # ```
      #
      # A font can also be made of the game's own pictures, in all their colours, such as a score
      # in the game's numerals or words in letters lifted off a cartridge. `pictures:` maps each
      # character to a picture declared with `image`. `strip:` is one picture cut into equal
      # pictures, one for each character of `characters:`, left to right, as a row of numerals is
      # kept in an original. A picture font draws each character as its picture, so it costs what
      # those pictures cost and nothing new. Its spacing is 0 unless given, since a picture carries
      # its own margin.
      #
      # ```ruby
      # font :numerals, pictures: ("0".."9").to_h { |d| [d, :"numeral_#{d}"] }
      # draw_number score, 8, 8, digits: 5, font: :numerals   # no colour: the pictures have theirs
      #
      # font :numerals, strip: :numeral_strip, characters: "0123456789 "
      # ```
      #
      # * `name` - the font's name, which `draw_text` takes as `font:`.
      # * `on:` - the character that marks a lit pixel in a glyph's art. The default is `"#"`.
      # * `spacing:` - blank pixels between characters. The default is 1, or 0 for pictures.
      # * `fold:` - `:upper` to draw any case with these glyphs.
      # * `glyphs:` - a hash from each character to rows of pixel values.
      # * `blank:` - the pixel value in `glyphs:` that is not drawn.
      # * `pictures:` - a hash from each character to a declared picture's name.
      # * `strip:` - a declared picture to cut, one piece for each character of `characters:`.
      # * `characters:` - the characters of `strip:`, left to right.
      # * `height:` - how tall each letter is, for `glyphs:` given as a data pack's pixels.
      #--
      # See PictureFonts and PictureFonts#declare_font_of_pack_pixels.
      #++
      def font(name, on: "#", spacing: nil, fold: nil, glyphs: nil, blank: 0, pictures: nil, strip: nil,
               characters: nil, height: nil, &block)
        if glyphs.is_a?(Hash) && glyphs.values.any?(DSL::PackSlot)
          raise ArgumentError, "font :#{name} takes a block or glyphs:, not both. Give one of them." if block
          return declare_font_of_pack_pixels(name, glyphs, height: height, blank: blank, spacing: spacing || 1, fold: fold)
        end
        unless height.nil?
          raise ArgumentError, "font :#{name} was given height:, which only a font of a data pack's pixels takes. " \
                               "To fix this, leave height: out."
        end
        if pictures || strip
          if block || glyphs || fold
            raise ArgumentError, "font :#{name} is made of pictures, so it takes no glyphs:, fold: or block. " \
                                 "Give pictures: or strip:, or glyphs: or a block."
          end

          return declare_picture_font(name, pictures: pictures, strip: strip, characters: characters,
                                            spacing: spacing || 0)
        end

        spacing ||= 1
        definition = Graphics::Font::Definition.new(name, on: on)
        if glyphs
          raise ArgumentError, "font :#{name} takes a block or glyphs:, not both. Give one of them." if block

          glyphs.each { |char, rows| definition.picture(char, rows, blank: blank) }
        else
          unless block
            raise ArgumentError,
                  "font :#{name} needs glyphs. Draw them in a block (font :#{name} do ... end), " \
                  "or give pictures of them (font :#{name}, glyphs: ...)."
          end

          definition.instance_eval(&block)
        end
        declare_font(name, definition.to_font(spacing: spacing, fold: fold))
        name
      end

      # Draws a line of words at a place: a label, a title, a line of dialogue.
      #
      # The words are fixed when the game is built. For a number that changes as the game runs,
      # such as a score, use `draw_number`: a live value cannot be put in a string, since Ruby
      # works out `"score: #{n}"` before the game runs.
      #
      # ```ruby
      # draw_text "PRESS START", 76, 100, :gray      # at a column you picked
      # draw_text "PRESS START", :center, 100, :gray # centred, whatever it says
      # ```
      #
      # The left edge takes a number, or `:left`, `:center` or `:right`, which put the line against
      # that edge of the screen. `within:` narrows what it is placed against: `within: 0..119`
      # centres a label in the left half, which is how a caption goes under a panel or a heading
      # over a menu window.
      #
      # The built-in font is 6 pixels a character and 7 pixels tall, and text is drawn in capitals.
      # A character that the font does not have is an error, since the words are known while the
      # game is built. Another font can be proportional, so ask `text_width` rather than
      # multiplying.
      #
      # To pick between two colours, give the colour as a pair and `showing:` the test that picks.
      # The second shows while the test holds, and the first when it does not. Written the long
      # way, as the same words drawn twice under a test and its opposite, it looks the same and
      # costs twice as much.
      #
      # ```ruby
      # draw_text "SOUND", 80, 60, [:gray, :white], showing: picked == 1
      # draw_text "HP",     8,  8, [:white, :red],  showing: hp < 20
      # ```
      #
      # * `text` - the words to draw, or a list of character codes with `from:` and `length:`.
      # * `x` - the left edge: a number, or `:left`, `:center` or `:right`.
      # * `y` - the top edge.
      # * `color` - the text colour, or a pair of colours to pick between. A font made of pictures
      #   needs none.
      # * `font:` - a font made with `font`. The default is the built-in one.
      # * `within:` - the columns to place it in, as a range. The default is the screen.
      # * `showing:` - the test that picks the second colour of a pair.
      # * `from:` and `length:` - for a list of character codes, where to start and how many to draw.
      # * `digits:` - for words with a number the game keeps in them (`"HP #{hp}"`, `hp.to_s`), the
      #   room each number takes, as `draw_number`'s `digits:`. The default is 4.
      #
      # A number the game keeps can go in the words, as Ruby puts one in a String. Each is drawn as
      # `draw_number` draws it, in the room that gives it, where the words before it end:
      #
      # ```ruby
      # draw_text "HP #{hp}", 8, 8, :white, digits: 3
      # ```
      #--
      # On a tiled screen the console draws each character as its own little sprite out of a table
      # of 128, so two draws are two sprites for every character where a colour pair is one sprite
      # that changes colour. On a bitmap screen the words are painted pixel by pixel, so two draws
      # are every pixel twice over where a pair paints them once with the colour picked first. A
      # menu's rows cost half as much for it (see the `menu` verb).
      #++
      def draw_text(text, x, y, color = nil, font: :default, within: nil, showing: nil, from: nil, length: nil,
                    digits: DEFAULT_DIGITS)
        if text.is_a?(DSL::TextWithNumbers)
          return draw_text_with_numbers(text, x, y, color, font: font, within: within, digits: digits)
        end
        if text.is_a?(DSL::List)
          refuse_list_in_picture_font!(font)
          return draw_list_text(text, x, y, color, font: font, from: from, length: length, placed: within || showing)
        end

        unless text.is_a?(String)
          raise ArgumentError,
                "draw_text draws words (a String, or a list of character codes). For a number like a score or a " \
                "counter, use draw_number. You gave #{Messages::PlainWords.words_for_given(text)}."
        end
        if from || length
          raise ArgumentError, "draw_text takes from: and length: with a list of character codes. These words are a String."
        end
        if picture_font?(font)
          return draw_text_in_pictures(text, x, y, color, font: font, within: within, showing: showing)
        end
        if lettering_font?(font)
          return draw_text_in_lettering(text, x, y, color, font: font, within: within, showing: showing)
        end

        refuse_missing_color!("draw_text", color)
        colors = text_colors!(color, showing)
        chosen = IR::FontTable.of(@program).get(font) # fail early with a friendly error on an unknown font name
        refuse_missing_characters!(text, chosen, font)
        x = column_for(x, chosen.text_width(text), within, "draw_text")
        refuse_unwritten_row!(y, "draw_text")

        # A tiled screen has no framebuffer to paint into, so text is drawn as little
        # sprite glyphs the console composites each frame — declared once, like a
        # sprite (see #draw_text_tiled).
        if TILE_HARDWARE_MODES.include?(@screen_mode)
          require_hud_declared_once!("draw_text")
          return draw_text_tiled(text, x, y, colors, font, showing)
        end

        return record(Build.draw_text(text, x, y, colors.first, font: font)) if colors.length == 1

        # A bitmap screen paints where it is called, and the words are the same words in
        # either colour — so they are painted once, with the test worked out first to pick
        # which colour. Written the long way, as the words under a test and again under its
        # opposite, it takes no longer and is every pixel of the words twice over.
        which = text_color_test(showing)
        consume_condition(which)
        record(Build.draw_text(text, x, y, colors.first, font: font, picked: colors.last, showing: which.node))
      end

      # Draws a whole number at a place: a score, a damage counter or a timer.
      #
      # The number can be fixed, a variable or a calculation. It is drawn without leading zeros and
      # right-aligned in a field of `digits:` columns, so the ones digit stays put and the number
      # grows to the left, the usual score look. It shows non-negative whole numbers. A value wider
      # than the field has its top places dropped, and there is no minus sign yet.
      #
      # ```ruby
      # draw_number 0,      8, 8, :white           # a fixed number
      # draw_number score,  8, 8, :white           # a live variable
      # draw_number hp - 1, 8, 8, :white           # a calculation
      # draw_number minutes, 8, 8, :white, digits: 2, leading_zeros: true   # 07
      # ```
      #
      # The left edge takes the same names as `draw_text`. What is placed is the field, not the
      # number in it. The field is the same width whatever the number is, which stops a centred
      # score from jittering as it counts up.
      #
      # * `value` - the number to draw.
      # * `x` - the left edge of the field: a number, or `:left`, `:center` or `:right`.
      # * `y` - the top edge.
      # * `color` - the digit colour. A font made of pictures needs none.
      # * `digits:` - how many digit columns to reserve. The default is 4.
      # * `font:` - a font made with `font`. The default is the built-in one.
      # * `within:` - the columns to place the field in, as a range.
      # * `leading_zeros:` - `true` fills the field with zeros, as a clock does: 7 in a field of two
      #   reads 07.
      def draw_number(value, x, y, color = nil, digits: DEFAULT_DIGITS, font: :default, within: nil, leading_zeros: false)
        unless DSL::Whole.positive?(digits)
          raise ArgumentError, "draw_number needs a positive number of digits, written in the program. " \
                               "You gave #{Messages::PlainWords.words_for_given(digits)}."
        end
        unless [true, false].include?(leading_zeros)
          raise ArgumentError, "draw_number takes leading_zeros: as true or false. Got #{leading_zeros.inspect}."
        end
        if picture_font?(font)
          return draw_number_in_pictures(value, x, y, color, font: font, digits: digits, within: within,
                                                             leading_zeros: leading_zeros)
        end
        if lettering_font?(font)
          return draw_number_in_lettering(value, x, y, color, font: font, digits: digits, within: within,
                                                              leading_zeros: leading_zeros)
        end

        refuse_missing_color!("draw_number", color)
        chosen = IR::FontTable.of(@program).get(font)
        x = column_for(x, (digits * chosen.cell_w) - chosen.spacing, within, "draw_number")
        refuse_unwritten_row!(y, "draw_number")

        # On a tiled screen, a number is drawn as sprite glyphs, declared once and
        # left to update itself each frame (see #draw_number_tiled).
        if TILE_HARDWARE_MODES.include?(@screen_mode)
          require_hud_declared_once!("draw_number")
          return draw_number_tiled(value, x, y, color, digits, font, leading_zeros)
        end

        case value
        when Integer        then draw_fixed_number(value, x, y, color, digits, font, leading_zeros)
        when Symbol, DSL::Value  then draw_live_number(value, x, y, color, digits, font, leading_zeros)
        else
          raise ArgumentError,
                "draw_number draws a number: a value, a variable, or an expression. Got #{value.inspect}."
        end
      end

      # Measures how wide some words come out, in pixels, when this screen draws them in a font.
      #
      # It is useful for anything sized to fit words, such as a box behind a title, a menu window as
      # wide as its longest row, or a rule under a heading.
      #
      # ```ruby
      # draw_rect_at 8, 8, text_width("SCORE") + 4, text_height + 4, :blue  # a box behind it
      # ```
      #
      # * `text` - the words to measure.
      # * `font:` - a font made with `font`. The default is the built-in one.
      def text_width(text, font: :default)
        unless text.is_a?(String)
          raise ArgumentError, "text_width measures words (a String). You gave #{Messages::PlainWords.words_for_given(text)}."
        end

        font_named(font).text_width(text)
      end

      # Measures how tall one line of text is, in pixels, as the other side of a box round it.
      #
      # * `font:` - a font made with `font`. The default is the built-in one.
      def text_height(font: :default) = font_named(font).height

      private

      # Words with numbers in them (DSL::TextWithNumbers): each run of words drawn as words, and each
      # number as `draw_number` draws it, in the `digits:` room that gives it, each a character's gap
      # after the one before, as the letters of one String are. What is placed by `x` is the whole.
      def draw_text_with_numbers(text, x, y, color, font:, within:, digits:)
        refuse_text_with_numbers!("a pair of colours") if color.is_a?(Array)
        refuse_text_with_numbers!("a font made of pictures") if picture_font?(font) || lettering_font?(font)
        chosen = IR::FontTable.of(@program).get(font)
        widths = text.parts.map { |part| part.is_a?(String) ? chosen.text_width(part) : (digits * chosen.cell_w) - chosen.spacing }
        at = column_for(x, widths.sum + (chosen.spacing * (widths.length - 1)), within, "draw_text")
        text.parts.zip(widths).each do |part, width|
          if !part.is_a?(String)
            draw_number(part, at, y, color, digits: digits, font: font)
          elsif !part.strip.empty?
            draw_text(part, at, y, color, font: font)
          end
          at += width + chosen.spacing
        end
      end

      def refuse_text_with_numbers!(what)
        raise ArgumentError, "draw_text cannot draw words with a game number in them in #{what}. To fix this, draw the " \
                             "words and the number apart: `draw_text \"HP\", 8, 8, :white`, then " \
                             "`draw_number hp, 32, 8, :white`.#{Messages::AuthorSource.at_author_line}"
      end

      # The font a name means: a font of the game's own pictures, else a font of glyphs.
      def font_named(name) = @picture_fonts[name] || @lettering_fonts[name]&.metrics || IR::FontTable.of(@program).get(name)

      def refuse_missing_color!(verb, color)
        return unless color.nil?

        raise ArgumentError,
              "#{verb} needs a colour after the place, like `#{verb} #{verb == 'draw_text' ? '"HI"' : ':score'}, 8, 8, :white`. " \
              "Only a font made of pictures draws with no colour."
      end

      # Words written in the game are known while it is built, so a character the font does not
      # have is said here. Left alone it is a gap in the line that only a look at the picture finds.
      def refuse_missing_characters!(text, chosen, font)
        missing = chosen.missing_characters(text)
        return if missing.empty?

        names = missing.map(&:inspect).join(", ")
        raise ArgumentError,
              "draw_text #{text.inspect}: font :#{font} has no #{names}. The text cannot show " \
              "#{missing.one? ? 'this character' : 'these characters'}. To fix this, use " \
              "#{missing.one? ? 'a different character' : 'different characters'}, or give `font:` a font that has " \
              "#{missing.one? ? 'it' : 'them'}. For an empty place, use a space."
      end

      # Put a declared font in the tree, the same way a declared picture goes in, so it
      # belongs to the game that wrote it. One name is one font (PictureFonts#refuse_font_name_taken!).
      def declare_font(name, font)
        refuse_font_name_taken!(name)
        record(Build.font(name, font))
      end

      # The colours the text can be drawn in, always as a list. One colour needs nothing
      # to choose between; two need a test, so a pair without `showing:` is refused
      # rather than one of them silently winning.
      #
      # Two and no more, on purpose. A pair with a test is one sprite that changes
      # colour, because a test is 0 or 1 and that is always one of the two. Three would
      # need the number the game gave held inside the list for it, which costs a check
      # on every character of every frame — and a third colour is rare enough that
      # writing the test out is the better trade. The error says so.
      def text_colors!(color, showing)
        unless color.is_a?(Array)
          return [color] if showing.nil?

          raise ArgumentError,
                "draw_text got `showing:` and one colour, so there is nothing to pick " \
                "between. Give two colours, like `[:gray, :white]`. Or drop `showing:`."
        end
        unless color.length == 2
          raise ArgumentError,
                "draw_text picks between two colours, and got #{color.length}. Give a pair, " \
                "like `[:gray, :white]`. For more, draw the text under a test for each."
        end
        return color if showing

        raise ArgumentError,
              "draw_text got two colours and needs `showing:` to say which one is on. " \
              "Give the test that picks the second, like `showing: picked == 1`."
      end

      # The test that picks the second colour. A Condition already answers 0 or 1, so it
      # is used as it is; anything else is read the way a game reads a flag — not zero
      # means yes.
      def text_color_test(showing)
        return showing if showing.is_a?(DSL::Condition)

        DSL::Value.new(self, DSL::Value.node_for(showing)) != 0
      end

      # The column to draw at, from the left edge a game asked for. A number passes
      # through untouched; a name is worked out from how wide the text really is and
      # how much room it is being placed in.
      def column_for(x, width, within, verb)
        return placed_column(x, width, within, verb) if ALIGNMENTS.include?(x)
        unless x.is_a?(Integer)
          raise ArgumentError,
                "#{verb} takes a left edge as a number written in the program, or as :left, :center or :right. " \
                "You gave #{Messages::PlainWords.words_for_given(x)}. Use one of those three names, or write the column."
        end
        return x unless within

        raise ArgumentError,
              "#{verb} got both a column (#{x}) and `within:`. A column already says exactly where " \
              "the text goes. Put :center, :left or :right where the number is, or drop `within:`."
      end

      # The row is settled while the game is built too: on a bitmap screen the words are painted
      # at a fixed place, and on a tiled one each letter is a sprite placed once. So the top edge
      # must be a number written in the program.
      def refuse_unwritten_row!(y, verb)
        return if y.is_a?(Integer)

        raise ArgumentError,
              "#{verb} takes a top edge as a number written in the program. " \
              "You gave #{Messages::PlainWords.words_for_given(y)}. To fix this, write the row."
      end

      def placed_column(align, width, within, verb)
        left, room = span_for(within, verb)
        case align
        when :left   then left
        when :center then left + ((room - width) / 2)
        else              left + room - width
        end
      end

      # What the text is placed against: the columns `within:` names, else the part of
      # the screen an `inside` block is holding drawing to, else the whole screen.
      # Following `inside` is what makes a heading over a panel centre on the panel.
      def span_for(within, verb)
        return columns_of(within, verb) if within
        return [@inside_area[0], @inside_area[2]] if @inside_area

        [0, read_screen_size(verb)[0]]
      end

      def columns_of(within, verb)
        first = within.first if within.is_a?(Range)
        unless first.is_a?(Integer) && within.last.is_a?(Integer)
          raise ArgumentError,
                "#{verb} takes `within:` as a span of columns written in the program, like `within: 8..119`. " \
                "You gave #{Messages::PlainWords.words_for_given(within)}."
        end

        [first, within.last - first + (within.exclude_end? ? 0 : 1)]
      end

      # Words held in a list (see DSL::ListText): +length+ of its character codes from item +from+,
      # all of it from there when not given. How wide they come out is known only as they are
      # drawn, so the left edge is a number or a variable, and each word of it is one colour.
      def draw_list_text(list, x, y, color, font:, from:, length:, placed:)
        if TILE_HARDWARE_MODES.include?(@screen_mode)
          raise ArgumentError, "draw_text cannot draw a list of character codes on a tiled screen, because each letter is a " \
                               "sprite made while the game is built. To fix this, use a `canvas` and call its draw_letter " \
                               "for each item of the list."
        end
        if x.is_a?(Symbol) && !@program.walk.any? { |node| node.kind == :var && node.name == x } || placed || color.is_a?(Array)
          raise ArgumentError, "draw_text of a list of character codes takes a column, not :left, :center, :right or within:, " \
                               "and one color with no showing:, because the words are not known until the game runs."
        end

        IR::FontTable.of(@program).get(font) # fail early with a friendly error on an unknown font name
        start = from || 0
        letters = length || (list.length - start)
        @list_texts ||= {}
        text = @list_texts[[list.name, font, color]] ||=
          DSL::ListText.new(self, number: @list_texts.length + 1, list: list, font: font, color: color)
        text.draw(x, y, start, letters)
      end

      # A number known at build time: right-align its glyphs in the field now. The
      # column step is the chosen font's cell width, so a narrower font packs tighter.
      def draw_fixed_number(number, x, y, color, digits, font, leading_zeros)
        text = leading_zeros ? number.to_s.rjust(digits, "0") : number.to_s
        col = [digits - text.length, 0].max * IR::FontTable.of(@program).get(font).cell_w
        record(Build.draw_text(text, x + col, y, color, font: font))
      end

      # A number only known at run time. Work it out once into a hidden var, then
      # draw each column. The bitmap font can't be indexed by a run-time digit, so
      # each column compares its value against 0..9 and draws the one that matches.
      # A "started" flag blanks the leading zeros so it reads as a natural number:
      # a column draws once a non-zero digit has appeared (the ones column always
      # draws, so a value of 0 still shows "0").
      #
      # Every column therefore carries all ten digit glyphs (one is drawn), so a
      # column costs about ten glyph blits of ROM — fine for a HUD; a run-time
      # glyph-by-index draw op would collapse each column to a single blit. With
      # +leading_zeros+ every column draws, as the ones column does.
      #
      # What a line keeps lives only while that line draws, so the lines of one routine share
      # where they keep it (Builder#step_variable), and a routine of a hundred numbers keeps three
      # words, not three hundred.
      def draw_live_number(value, x, y, color, digits, font, leading_zeros)
        source = number_source(value)
        digit = step_variable(:number_digit).name
        started = step_variable(:number_started).name unless leading_zeros
        store!(started, 0) unless leading_zeros

        cell = IR::FontTable.of(@program).get(font).cell_w
        digits.times do |i|
          place = 10**(digits - 1 - i)
          store!(digit, digit_at(source, place))
          col_x = x + i * cell
          if i == digits - 1 || leading_zeros
            draw_glyph(digit, col_x, y, color, font) # the ones column always shows
          else
            emit_conditional(:ne, digit, 0) { store!(started, 1) }
            emit_conditional(:eq, started, 1) { draw_glyph(digit, col_x, y, color, font) }
          end
        end
        nil
      end

      # Draw the single digit held in +digit_var+ (0..9) at (x, y) as one
      # draw_digit node in the named font — the tree keeps "draw one digit here" as a
      # single intent, and the backend decides how to render it (a font lookup, or a
      # fan-out).
      def draw_glyph(digit_var, x, y, color, font)
        ensure_var(digit_var)
        record(Build.draw_digit(Build.var_ref(digit_var), x, y, color, font: font))
      end

      # The value node for one digit column of the number in +source+:
      # (source / place) mod 10, spelled out as q - (q / 10) * 10 — a true remainder for
      # a non-negative q, and a number on screen is never negative.
      def digit_at(source, place)
        quotient = source_over_place(source, place)
        tens = Build.binop(:/, quotient, Build.int(10))
        Build.binop(:-, quotient, Build.binop(:*, tens, Build.int(10)))
      end

      # source / place, skipping the divide for the ones column (place == 1).
      def source_over_place(source, place)
        ref = Build.var_ref(source)
        place == 1 ? ref : Build.binop(:/, ref, Build.int(place))
      end

      # The variable a live number's digits are read from: the number, copied once as the line
      # starts, into a variable the routine's lines share.
      #
      # A copy even of a variable, because every column reads it. On the Advance a timer's handler
      # can stop the line between two columns and change the variable, and a clock going from 10
      # to 9 there would show 19.
      #
      # A fraction keeps a copy of its own, since the variable it is copied into holds a fraction
      # from then on.
      def number_source(value)
        source = value.is_a?(DSL::Value) && value.fraction? ? next_number_var : step_variable(:number_source).name
        store!(source, value)
        source
      end

      # A fresh hidden variable name for one draw_number call's fraction.
      # Named per call site, reused every frame.
      def next_number_var
        @number_seq += 1
        :"__number_#{@number_seq}"
      end

      # --- tiled-mode text: glyphs drawn as sprites -------------------------------
      #
      # A tiled screen draws from tiles and sprites, not a framebuffer, so there's
      # nowhere for the bitmap draw_text/draw_number to plot pixels. Instead each
      # character becomes a tiny hardware sprite — one 8x8 glyph — that the console
      # composites over the game every frame. Because a sprite is drawn for you each
      # frame, tiled text is declared once (before the game loop, like `sprite`) and
      # then stays; a live number's sprite chooses which digit to show from its value
      # each frame, so it updates itself with nothing to call in the loop.

      # A glyph fits in one 8x8 sprite tile.
      HUD_GLYPH_PX = 8  # :nodoc:

      # Draw a fixed string as a row of glyph sprites at (x, y), each advancing by its
      # own width the way the bitmap pen does, so a proportional font stays proportional.
      # A space or a character the font lacks draws nothing but still takes its room, so
      # leaving its sprite out moves nothing after it.
      #
      # And leaving it out is worth doing: the console draws 128 sprites at once, a
      # character is one of them, and a sprite with no lit pixels in it would spend a
      # slot to paint nothing at all. A HUD line with two spaces in it is two slots
      # back for the game.
      # A pair of colours becomes a pair of poses on the one sprite — the same glyph
      # twice, once in each colour, with the test choosing between them every frame.
      # That is the whole saving: the console is already changing which picture each
      # sprite shows for free, so a label that changes colour costs no more slots than
      # one that does not. Written as two draws under a test it would be two sprites for
      # every character, one of them always hidden.
      #
      # The pose must always land inside the pair or the console reads tiles that are
      # not there, so a test is what this takes: a test is 0 or 1, and a pair has a
      # 0 and a 1.
      def draw_text_tiled(text, x, y, colors, font, showing)
        f = IR::FontTable.of(@program).get(font)
        pose = colors.length == 1 ? Build.int(0) : glyph_color_pose(showing)
        f.each_glyph_x(text) do |ch, dx|
          next if f.glyph_pixels(ch).zero? # a space, or a character the font lacks: nothing to draw

          hud_glyph_object(poses: colors.map { |c| glyph_image(font, ch, c) }, pose: pose.copy,
                           x: x + dx, y: y)
        end
        nil
      end

      # Which of a glyph's two colours to show, as a value node that is only ever 0 or 1.
      # A Condition's node already is one; a plain value is read as a flag. Each glyph
      # gets its own copy, because a node belongs to one place in the tree.
      def glyph_color_pose(showing)
        test = text_color_test(showing)
        consume_condition(test)
        test.node
      end

      # Draw a number as glyph sprites. A fixed number is just its right-aligned
      # digits (like draw_text). A live number gets one sprite per digit column, each
      # showing the matching glyph for its place in the value — recomputed every frame
      # from the variable, with leading zeros left blank so it reads naturally.
      def draw_number_tiled(value, x, y, color, digits, font, leading_zeros)
        cell = IR::FontTable.of(@program).get(font).cell_w
        fixed = DSL::Value.fixed_number(value)
        if fixed
          text = leading_zeros ? fixed.to_s.rjust(digits, "0") : fixed.to_s
          pad = [digits - text.length, 0].max # right-align in the field
          return draw_text_tiled(text, x + pad * cell, y, [color], font, nil)
        end

        source = hud_number_variable(value)
        poses = [blank_glyph_image] + ("0".."9").map { |d| glyph_image(font, d, color) }
        digits.times do |i|
          place = 10**(digits - 1 - i)
          hud_glyph_object(poses: poses, pose: hud_digit_pose(source, place, leading_zeros: leading_zeros),
                           x: x + i * cell, y: y)
        end
        nil
      end

      # The variable a live tiled number tracks. A digit column reads it every frame,
      # so it must be a plain variable (a Symbol, or a `var` handle), not a one-off
      # expression — there's no per-frame place to recompute an expression into.
      def hud_number_variable(value)
        name = value.is_a?(Symbol) ? value : (value.node.name if value.node.kind == :var_ref)
        return name if name

        raise ArgumentError,
              "On a tiled screen, draw_number follows a variable and updates itself each frame. " \
              "Give it a variable (like :score), not an expression. Store the value in a variable " \
              "first (for example `shown = var :shown, 0`, then `shown = hp - 1`). Then draw that " \
              "variable."
      end

      # The sprite pose that shows the digit of +source+ at +place+ (1, 10, 100, …).
      # Pose 0 is the blank glyph and poses 1..10 are the digits 0..9, so the value to
      # show is (that digit + 1). Every column but the ones column blanks out while the
      # number hasn't reached its place yet — that's what drops the leading zeros —
      # which is exactly `(source >= place)` (0 or 1) times the digit-plus-one. With
      # +leading_zeros+ every column shows its digit, as the ones column does.
      def hud_digit_pose(source, place, leading_zeros: false)
        show = Build.binop(:+, digit_at(source, place), Build.int(1))
        return show if place == 1 || leading_zeros

        Build.binop(:*, Build.binop(:>=, Build.var_ref(source), Build.int(place)), show)
      end

      # Declare one glyph sprite (an object) at a fixed screen spot and remember it so
      # every frame's repaint draws it, on top of the game.
      # +shown_while+, a value node of 0 or 1, hides it while it is 0.
      def hud_glyph_object(poses:, pose:, x:, y:, shown_while: Build.int(1))
        name = :"__hud#{@sprite_seq += 1}"
        # A HUD glyph is always shown, so active starts at 1 — and then picks up the two
        # things that can narrow it. gated_by_scene scopes it to when its scene is the live
        # one, so a scene's HUD comes and goes with the scene. gated_by_open_conditions carries the
        # tests it was written under, so `draw_text ... if blink == 1` blinks
        # instead of standing still. Neither needs anything toggled by hand.
        record(Build.object(name, poses: poses, pose: pose, x: Build.int(x), y: Build.int(y),
                                  active: gated_by_open_conditions(gated_by_scene(shown_while)),
                                  scene: declaring_scene))
        @hud_objects << name
        name
      end

      # The image name for one glyph of a font in a color — an 8x8 sprite tile with the
      # glyph's lit pixels in that color and everything else transparent. Cached, so a
      # digit reused across columns (or a repeated letter) is built once.
      def glyph_image(font_name, char, color)
        @glyph_images[[font_name, char, color]] ||= begin
          font = IR::FontTable.of(@program).get(font_name)
          fits_glyph_tile!(font_name, font)
          data = Array.new(HUD_GLYPH_PX * HUD_GLYPH_PX, Images::TRANSPARENT_PIXEL)
          font.each_pixel(char.to_s) { |dx, dy| data[(dy * HUD_GLYPH_PX) + dx] = color }
          name = :"__glyph#{@glyph_images.size}"
          define_pixel_image(name, width: HUD_GLYPH_PX, height: HUD_GLYPH_PX,
                                   data: data, transparent: Images::TRANSPARENT_PIXEL)
          name
        end
      end

      # The all-transparent glyph a digit column shows for a leading zero.
      def blank_glyph_image
        @blank_glyph_image ||= begin
          data = Array.new(HUD_GLYPH_PX * HUD_GLYPH_PX, Images::TRANSPARENT_PIXEL)
          define_pixel_image(:__glyph_blank, width: HUD_GLYPH_PX, height: HUD_GLYPH_PX,
                                             data: data, transparent: Images::TRANSPARENT_PIXEL)
          :__glyph_blank
        end
      end

      # A glyph must fit one 8x8 sprite tile in tiled mode. The built-in :default (5x7)
      # and :tiny (3x5) do; a taller/wider custom font would need a bigger sprite, which
      # isn't wired up yet — so say so plainly rather than clip the glyph. An imported
      # font is usually too big because of one or two wide characters, so name the widest
      # one: that is what a person has to look at.
      def fits_glyph_tile!(font_name, font)
        return if font.cell_w <= HUD_GLYPH_PX && font.height <= HUD_GLYPH_PX

        widest = font.widest_character
        culprit = if font.cell_w > HUD_GLYPH_PX && widest
                    " Its widest character is #{widest.inspect}, at #{font.glyph_width(widest)} pixels across."
                  else
                    ""
                  end
        raise ArgumentError,
              "On a tiled screen, the console draws text as #{HUD_GLYPH_PX}x#{HUD_GLYPH_PX} sprite glyphs. " \
              "Font :#{font_name} is #{font.cell_w}x#{font.height} per character. That is too big for one glyph tile." \
              "#{culprit} " \
              "Use a smaller font (the built-in :default and :tiny fit), or draw this text on a `screen :bitmap`."
      end

      # Text a verb draws for you, rather than text the author placed — a `menu`'s rows.
      # While this is in force, the "declare it once, above the game_loop" rule below
      # does not apply.
      #
      # That is not the rule being weakened, because the rule was never about this text.
      # It is about an author's own call site: tiled text is declared once and redrawn
      # for you every frame, and making the author write the call above the loop is what
      # makes that visible. A verb that owns its drawing has no call site to misplace —
      # the author wrote `menu`, and where a menu goes is decided by menu's own rule,
      # which is per-frame work and the same on both screens.
      #
      # It holds the verb's name rather than a flag, because the other rule this text
      # meets does still apply and only its wording needs fixing: a bitmap menu really
      # cannot belong to a layer, and the message should say `menu` — what the author
      # wrote — rather than `draw_text`, which they never typed (see
      # Layers#refuse_painting_in_layer!).
      #
      # Same idea as the `wrote:` a routine carries (see Scenes#declare_func): a
      # diagnostic is for what a person typed, and the framework's own emissions are
      # never its subject.
      def with_text_owned_by(verb)
        outer = @verb_owns_text
        @verb_owns_text = verb
        yield
      ensure
        @verb_owns_text = outer
      end

      # The containers that are a test rather than a per-frame body — an `if` and its
      # `else`. Text declared under one of these is declared once, like text at the top
      # level, and shown while the test holds.
      CONDITION_CONTAINERS = %i[if else].freeze  # :nodoc:

      # Tiled text is declared once and redrawn for you every frame, so it belongs at
      # the top level (before game_loop), not inside the loop — declared inside, it
      # would be re-added every frame and never make it into the frame's sprite list.
      # Point at the fix rather than let a HUD silently fail to appear.
      def require_hud_declared_once!(verb)
        return if @verb_owns_text # a menu's rows: the verb owns them, not the call site
        return if @container_stack.length == 1 # only the program itself is open
        return if @building_scene # a scene declares its own HUD in its body (built once, off the loop)
        # A test around the call is still one declaration, not a per-frame one: the block
        # runs once while the program is built, and the condition rides onto the glyph so
        # it is shown while the test holds (see Builder#gated_by_open_conditions). That is how a
        # prompt blinks, so it is allowed — what stays refused is a per-frame body.
        return if @container_stack.drop(1).all? { |open| CONDITION_CONTAINERS.include?(open.kind) }

        raise ArgumentError,
              "Call #{verb} once, above your game_loop. Do not call it inside the loop. " \
              "On a tiled screen, the console redraws the text every frame (like a sprite). " \
              "You declare it once and it stays. If it shows a value that changes, pass the variable and it updates itself."
      end
    end
  end
end
