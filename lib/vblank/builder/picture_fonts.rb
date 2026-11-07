# frozen_string_literal: true

module VBlank
  class Builder
    # Fonts whose characters are the game's own pictures (Graphics::PictureFont): declaring one
    # from pictures by character or from one strip cut into equal pictures, and drawing words
    # and numbers in it. A concern of {Builder}; the verbs are Text's `font`, `draw_text` and
    # `draw_number`, which hand a picture font's work to here.
    #
    # Nothing goes in the tree for the font itself. Each character is drawn as what every
    # console already draws: on a bitmap screen a `blit` of its picture, on a tiled one a sprite
    # showing it. So a picture font needs nothing of its own from any backend.
    module PictureFonts
      # The hidden variables a live number's digit routine reads: which picture, and where.
      DIGIT_SHOWN = :__picture_digit_shown
      DIGIT_COLUMN = :__picture_digit_column
      DIGIT_ROW = :__picture_digit_row

      private

      # Whether +name+ is a font of the game's own pictures.
      def picture_font?(name) = @picture_fonts.key?(name)

      # Declare a font of pictures: +pictures+ maps each character to a declared picture, or
      # +strip+ names one picture to cut into equal pictures, one for each of +characters+, left
      # to right. The pictures may differ in width, so letters can be proportional, but not in
      # height, since a line is one height. A number asks more of them (#refuse_unfit_numerals!).
      def declare_picture_font(name, pictures:, strip:, characters:, spacing:)
        refuse_font_name_taken!(name)
        if pictures && strip
          raise ArgumentError, "font :#{name} takes pictures: or strip:, not both. Give one of them."
        end

        pictures = pictures_cut_from_strip(name, strip, characters) if strip
        refuse_unusable_pictures!(name, pictures)
        sizes = pictures.to_h do |char, picture|
          size = @images[picture] or
            raise ArgumentError,
                  "font :#{name} names the picture :#{picture} for #{char.inspect}, and no picture has that name. " \
                  "To fix this, declare it first with `image :#{picture}, ...`."
          [char, size]
        end
        refuse_picture_heights_differ!(name, pictures, sizes)
        @picture_fonts[name] = Graphics::PictureFont.new(pictures: pictures, sizes: sizes, spacing: spacing)
        name
      end

      def refuse_unusable_pictures!(name, pictures)
        usable = pictures.is_a?(Hash) && pictures.all? do |char, picture|
          char.is_a?(String) && char.length == 1 && picture.is_a?(Symbol)
        end
        unless usable
          raise ArgumentError,
                "font :#{name} takes pictures: as each character and the name of its picture, " \
                "like `pictures: { \"0\" => :zero, \"1\" => :one }`. Got #{pictures.inspect}."
        end
        raise ArgumentError, "font :#{name} has no pictures. Give it at least one." if pictures.empty?
      end

      def refuse_picture_heights_differ!(name, pictures, sizes)
        tallest = sizes.values.first[1]
        other = sizes.keys.find { |char| sizes[char][1] != tallest }
        return unless other

        raise ArgumentError,
              "font :#{name}: the picture :#{pictures[other]} is #{sizes[other][1]} pixels tall, and " \
              ":#{pictures[sizes.keys.first]} is #{tallest}. All the pictures of a font must be one height. " \
              "To fix this, make them the same height."
      end

      # One name is one font, of whichever kind: a second `font :hud` is a mistake, and what it
      # would draw with is the first one, which reads as the art being wrong.
      def refuse_font_name_taken!(name)
        return unless picture_font?(name) || IR::FontTable.of(@program).declared?(name)

        raise ArgumentError,
              "font :#{name} is declared twice. Each font needs its own name. To fix this, rename one of them."
      end

      # A picture cut into one picture for each of +characters+, all as wide, left to right: a row
      # of numerals as the original keeps it. Each piece is a picture of its own, named after the
      # strip, so it draws however a picture does.
      def pictures_cut_from_strip(font_name, strip, characters)
        unless characters.is_a?(String) && !characters.empty? && characters.chars.uniq.length == characters.length
          raise ArgumentError,
                "font :#{font_name} cuts strip: :#{strip} by characters:, a String with each character once, " \
                "left to right, like `characters: \"0123456789\"`. Got #{characters.inspect}."
        end
        width, height = @images[strip] || raise(ArgumentError,
                                                "font :#{font_name} cuts the picture :#{strip}, and no picture has that " \
                                                "name. To fix this, declare it first with `image :#{strip}, ...`.")
        unless (width % characters.length).zero?
          raise ArgumentError,
                "font :#{font_name}: the strip :#{strip} is #{width} pixels wide, and that does not cut into " \
                "#{characters.length} pictures of one width. To fix this, make the strip a whole number of pictures wide."
        end

        piece_width = width / characters.length
        characters.each_char.with_index.to_h do |char, at|
          piece = :"#{strip}_#{at}"
          declare_strip_piece(font_name, strip, piece, at * piece_width, piece_width, height)
          [char, piece]
        end
      end

      # One piece of a strip, from +left+, +width+ across. A strip made from a data pack's tiles
      # is cut by its tiles, so the piece reads the pack as the strip does (a build that reads its
      # pack as the game starts has no pixels to cut); any other is cut from its pixels.
      def declare_strip_piece(font_name, strip, piece, left, width, height)
        options = @pack_picture_options[strip]
        return image(piece, options.merge(width: width, places: strip_piece_tiles(font_name, strip, options[:places], left, width))) if options

        node = @program.walk.find { |found| found.kind == :bitmap && found.name == strip }
        unless node
          raise ArgumentError,
                "font :#{font_name} cannot cut :#{strip}, because it is not a picture held in the cartridge. " \
                "To fix this, cut a picture made with `image`."
        end

        pixels = node.pixels.unpack("v*")
        data = (0...height).flat_map { |row| pixels[(row * node.width) + left, width] }
        define_pixel_image(piece, width: width, height: height, data: data, transparent: node.transparent)
      end

      def strip_piece_tiles(font_name, strip, tiles, left, width)
        side = Original::Slot::TILE_SIDE
        unless tiles.down == 1 && (width % side).zero?
          raise ArgumentError,
                "font :#{font_name}: the strip :#{strip} is made from a data pack's tiles, and it is cut by its tiles. " \
                "To fix this, make the strip one tile tall and each picture a whole number of tiles wide."
        end

        tiles.with(tile_index: tiles.tile_index + (left / side), across: width / side)
      end

      # A picture font's pictures have their own colours, so a colour given beside it would be
      # ignored, and a game that gave one expects to see it.
      def refuse_color_for_picture_font!(verb, font, color, showing)
        return if color.nil? && showing.nil?

        raise ArgumentError,
              "#{verb} with font :#{font} draws the font's own pictures, in their own colours. It takes no colour. " \
              "To fix this, remove #{color.nil? ? 'showing:' : color.inspect}."
      end

      def refuse_list_in_picture_font!(font)
        return unless picture_font?(font)

        raise ArgumentError,
              "draw_text cannot draw a list of character codes in font :#{font}, because its letters are pictures. " \
              "To fix this, draw the words as a String, or use a font of glyphs."
      end

      # draw_text in a picture font: each character's picture where the pen puts it.
      def draw_text_in_pictures(text, x, y, color, font:, within:, showing:)
        picture_font = @picture_fonts[font]
        refuse_color_for_picture_font!("draw_text", font, color, showing)
        refuse_missing_characters!(text, picture_font, font)
        draw_pictures_of(text, column_for(x, picture_font.text_width(text), within, "draw_text"), y, picture_font)
      end

      # Words at a column already worked out. On a bitmap screen each character is a blit; on a
      # tiled one, a sprite declared once and shown every frame, as any tiled text is.
      def draw_pictures_of(text, x, y, picture_font)
        tiled = Text::TILE_HARDWARE_MODES.include?(@screen_mode)
        require_hud_declared_once!("draw_text") if tiled
        picture_font.each_glyph_x(text) do |char, dx|
          picture = picture_font.picture(char)
          if tiled
            hud_glyph_object(poses: [picture], pose: Build.int(0), x: x + dx, y: y)
          else
            blit(picture, x + dx, y)
          end
        end
        nil
      end

      # draw_number in a picture font, in a field of +digits+ columns, each as wide as the widest
      # picture, placed and right-aligned as any number is. A place the number has not reached
      # is a leading nought: the "0" picture with +leading_zeros+, else the font's space where it
      # has one (which paints over the digit that was there), else nothing.
      def draw_number_in_pictures(value, x, y, color, font:, digits:, within:, leading_zeros:)
        picture_font = @picture_fonts[font]
        refuse_color_for_picture_font!("draw_number", font, color, nil)
        cell = picture_font.cell_w
        x = column_for(x, (digits * cell) - picture_font.spacing, within, "draw_number")
        fixed = DSL::Value.fixed_number(value)
        return draw_fixed_number_in_pictures(fixed, x, y, picture_font, font, digits, leading_zeros) if fixed

        numerals = refuse_unfit_numerals!(picture_font, font)
        blank = leading_zeros ? nil : picture_font.picture(" ")
        if Text::TILE_HARDWARE_MODES.include?(@screen_mode)
          require_hud_declared_once!("draw_number")
          return draw_live_number_in_sprites(value, x, y, cell, numerals, blank, digits, leading_zeros)
        end
        unless value.is_a?(Symbol) || value.is_a?(DSL::Value)
          raise ArgumentError, "draw_number draws a number: a value, a variable, or an expression. Got #{value.inspect}."
        end

        draw_live_number_in_pictures(value, x, y, font, cell, numerals, blank, digits, leading_zeros)
      end

      def draw_fixed_number_in_pictures(number, x, y, picture_font, font, digits, leading_zeros)
        text = number.to_s
        pad = [digits - text.length, 0].max
        filler = leading_zeros ? "0" : (" " if picture_font.picture(" "))
        refuse_missing_characters!(text + filler.to_s, picture_font, font)
        return draw_pictures_of((filler * pad) + text, x, y, picture_font) if filler

        draw_pictures_of(text, x + (pad * picture_font.cell_w), y, picture_font)
      end

      # A live number on a bitmap screen. Each column works out which picture to show, a digit,
      # or the space (-1 where there is none, which draws nothing), and calls one routine that
      # draws it: the routine is the font's, written once, because a blit of one of ten pictures
      # is a test and a copy for each, and written at every column of every number that is most
      # of a cartridge's code.
      def draw_live_number_in_pictures(value, x, y, font, cell, numerals, blank, digits, leading_zeros)
        source = next_number_var
        store!(source, value)
        # A tear-free screen draws a picture only at a column it can prove even. Columns known
        # to be even are handed over halved and doubled in the routine, which proves it.
        halved = x.even? && cell.even?
        routine = picture_digit_routine(font, numerals + [blank].compact, halved)
        blank_index = blank ? 10 : -1
        digits.times do |i|
          place = 10**(digits - 1 - i)
          leading = place != 1 && !leading_zeros
          store!(DIGIT_SHOWN, leading ? digit_or_blank(source, place, blank_index) : digit_at(source, place))
          store!(DIGIT_COLUMN, halved ? (x + (i * cell)) / 2 : x + (i * cell))
          store!(DIGIT_ROW, y)
          call routine
        end
        nil
      end

      # The routine that draws one of +poses+ by DIGIT_SHOWN at DIGIT_COLUMN, DIGIT_ROW, declared
      # the first time a number in +font+ needs it.
      def picture_digit_routine(font, poses, halved)
        routine = :"__picture_digits_#{font}#{'_halved' if halved}"
        return routine if @functions.key?(routine)

        declare_func(routine) do
          column = DSL::Value.new(self, Build.var_ref(DIGIT_COLUMN))
          blit(poses, halved ? column * 2 : column, DIGIT_ROW, showing: DIGIT_SHOWN)
        end
        routine
      end

      # The digit of +source+ at +place+, or +blank+ while the number is smaller than the place:
      # blank + (source >= place) * (digit - blank), with no test to branch on.
      def digit_or_blank(source, place, blank)
        reached = Build.binop(:>=, Build.var_ref(source), Build.int(place))
        Build.binop(:+, Build.int(blank), Build.binop(:*, reached, Build.binop(:-, digit_at(source, place), Build.int(blank))))
      end

      # A live number on a tiled screen: a sprite for each column, read from its variable every
      # frame. With the space, its pose is the space or one of the ten digits (see
      # #hud_digit_pose). Without, its pose is the digit and a leading nought hides the sprite:
      # a picture of nothing would have to share the numerals' colours, which a picture from a
      # data pack has only as the game runs.
      def draw_live_number_in_sprites(value, x, y, cell, numerals, blank, digits, leading_zeros)
        source = hud_number_variable(value)
        digits.times do |i|
          place = 10**(digits - 1 - i)
          at = x + (i * cell)
          if blank
            hud_glyph_object(poses: [blank] + numerals, pose: hud_digit_pose(source, place), x: at, y: y)
          else
            reached = place == 1 || leading_zeros ? Build.int(1) : Build.binop(:>=, Build.var_ref(source), Build.int(place))
            hud_glyph_object(poses: numerals, pose: digit_at(source, place), x: at, y: y, shown_while: reached)
          end
        end
        nil
      end

      # A number can show any digit, and shows each in the same column, so a picture font draws
      # a live number only when it holds all ten and they are one size (with the space too, if it
      # has one). Returns the ten pictures, nought first.
      def refuse_unfit_numerals!(picture_font, font)
        missing = picture_font.missing_characters("0123456789")
        unless missing.empty?
          raise ArgumentError,
                "draw_number: font :#{font} has no #{missing.map(&:inspect).join(', ')}. A number that changes can " \
                "show any digit, so the font needs a picture for each of 0 to 9. To fix this, add the missing pictures."
        end

        numerals = ("0".."9").map { |digit| picture_font.picture(digit) }
        sizes = (numerals + [picture_font.picture(" ")].compact).map { |picture| @images[picture] }.uniq
        return numerals if sizes.one?

        raise ArgumentError,
              "draw_number: font :#{font} has pictures of different sizes for its digits. A number draws each digit in " \
              "the same place, so the pictures of 0 to 9, and of the space, must be one size. To fix this, make them " \
              "the same size."
      end
    end
  end
end
