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

      # A font of a pack's pixels with the pack left out (#declare_lettering_font): its letters'
      # slices by character, the byte that is not lit, and its widths and spacing as a font of
      # pictures (+metrics+).
      Lettering = Data.define(:slices, :blank, :metrics)

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
        return unless picture_font?(name) || lettering_font?(name) || IR::FontTable.of(@program).declared?(name)

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
      # pack as the game starts has no pixels to cut). Any other strip read from the pack as the
      # game starts is cut where it is in the pack, each piece reading its own part
      # (DataPacks#define_piece_read_from_start_file). The rest are cut from their pixels.
      def declare_strip_piece(font_name, strip, piece, left, width, height)
        options = @pack_picture_options[strip]
        return image(piece, options.merge(width: width, places: strip_piece_tiles(font_name, strip, options[:places], left, width))) if options

        if picture_from_start_file?(strip)
          return define_piece_read_from_start_file(piece, strip, left: left, width: width) ||
                 refuse_strip_not_cut_at_start!(font_name, strip)
        end

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

      # A strip the build holds no pixels of, and whose pieces are not parts of the pack as it is
      # kept: cut from the zeros the build holds, every letter would be drawn empty.
      def refuse_strip_not_cut_at_start!(font_name, strip)
        raise ArgumentError,
              "font :#{font_name} cannot cut the strip :#{strip}. This build reads that picture from the data pack as " \
              "the game starts, and a picture that is turned, or that is a frame of the original, cannot be cut then. " \
              "To fix this, give the font a picture for each character with pictures:, or build the game all-in-one."
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

      # A FONT OF A DATA PACK'S PIXELS: an alphabet as a computer game keeps it, each letter a run
      # of a slot of pixels, one byte a pixel, row by row, +height+ rows, lit where the byte is not
      # +blank+, and written in the colour draw_text asks, as a font of glyphs is.
      #
      #   font :lettering, glyphs: { "A" => pack[:font].pixels(0, 70), ... }, height: 10
      #
      # Each letter is as wide as its pixels over the height, so the font is proportional. Where the
      # build reads the pack (every cartridge, and a computer build all-in-one), the letters are read
      # here and the font IS a font of glyphs given as rows, so it draws, measures and places alike on
      # every console. Where the build leaves the pack out, nothing knows which pixels are lit until the
      # game starts, so each letter becomes a picture of the slot's pixels in one colour, a picture for
      # each colour the game writes in (#picture_font_of_lettering), and words are drawn as a font of
      # pictures is. That build cannot draw a list of character codes in it, nor take fold:.
      def declare_font_of_pack_pixels(name, glyphs, height:, blank:, spacing:, fold:)
        refuse_font_name_taken!(name)
        refuse_unfit_pack_glyphs!(name, glyphs, height, blank)
        if pack_left_out?
          declare_lettering_font(name, glyphs, height: height, blank: blank, spacing: spacing, fold: fold)
        else
          declare_glyph_font_of_pack_bytes(name, glyphs, height: height, blank: blank, spacing: spacing, fold: fold)
        end
        name
      end

      # The font with the pack read: each letter's bytes as rows, a font of glyphs.
      def declare_glyph_font_of_pack_bytes(name, glyphs, height:, blank:, spacing:, fold:)
        definition = Graphics::Font::Definition.new(name)
        glyphs.each do |char, slice|
          bytes = @data_pack_contents.bytes_of(slice.layout.name).byteslice(slice.first_pixel, slice.count).bytes
          definition.picture(char, bytes.each_slice(slice.count / height).to_a, blank: blank)
        end
        declare_font(name, definition.to_font(spacing: spacing, fold: fold))
      end

      # The font with the pack left out: kept as a Lettering until the game writes in a colour.
      def declare_lettering_font(name, glyphs, height:, blank:, spacing:, fold:)
        unless fold.nil?
          raise ArgumentError, "font :#{name} reads its letters from the pack as the game starts. " \
                               "Such a font cannot fold one case into another. To fix this, give a letter for each case. " \
                               "Or build the game all-in-one."
        end

        sizes = glyphs.transform_values { |slice| [slice.count / height, height] }
        # The widths only: a Lettering has no pictures until a colour is asked for.
        metrics = Graphics::PictureFont.new(pictures: glyphs.transform_values { nil }, sizes: sizes, spacing: spacing)
        @lettering_fonts[name] = Lettering.new(slices: glyphs, blank: blank, metrics: metrics)
      end

      def lettering_font?(name) = @lettering_fonts.key?(name)

      def refuse_unfit_pack_glyphs!(name, glyphs, height, blank)
        unless height.is_a?(Integer) && height.positive?
          raise ArgumentError, "font :#{name} takes its letters from a data pack's pixels, and needs height:, how many " \
                               "rows each letter is. To fix this, add height:, like `height: 10`."
        end
        unless blank.is_a?(Integer) && blank.between?(0, 255)
          raise ArgumentError, "font :#{name} takes its letters from a data pack's pixels, so blank: is a byte, 0 to 255. " \
                               "Got #{blank.inspect}."
        end
        glyphs.each do |char, slice|
          unless char.is_a?(String) && char.length == 1 && slice.is_a?(DSL::PackSlot) && slice.shape == :pixels
            raise ArgumentError, "font :#{name} takes glyphs: as each character and a run of a slot of pixels, like " \
                                 "`\"A\" => pack[:font].pixels(0, 70)`. Got #{char.inspect} => #{slice.inspect}."
          end
          refuse_slot_from_elsewhere!(slice, "font :#{name}'s letter #{char.inspect}")
          next if (slice.count % height).zero?

          raise ArgumentError, "font :#{name}: the letter #{char.inspect} is #{slice.count} pixels, and that is not " \
                               "rows of height: #{height}. To fix this, give each letter a whole number of rows."
        end
      end

      # The font of pictures that writes font +name+ (a Lettering) in +color+: a picture of each
      # letter's pixels with every lit byte that colour, declared the first time the game writes in
      # it. Its name is the font's own with the colour, so each colour is one set of pictures however
      # often it is used.
      def picture_font_of_lettering(name, color)
        value = Graphics::Color.resolve(color)
        colored = :"__#{name}_in_#{value.to_s(16)}"
        return colored if picture_font?(colored)

        lettering = @lettering_fonts.fetch(name)
        pictures = lettering.slices.each_with_index.to_h do |(char, slice), k|
          picture = :"#{colored}_#{k}"
          define_picture_of_pack_pixels(picture, width: lettering.metrics.glyph_width(char), height: lettering.metrics.height, places: slice,
                                                 colors: Array.new(DataPacks::MOST_PIXEL_PLACES, value), see_through: lettering.blank)
          [char, picture]
        end
        declare_picture_font(colored, pictures: pictures, strip: nil, characters: nil, spacing: lettering.metrics.spacing)
      end

      # draw_text in a font of a pack's pixels with the pack left out: each letter's picture in the
      # colour asked, or in a pair of colours, each letter picking between its two pictures by the
      # test, as a font of glyphs picks its colour.
      def draw_text_in_lettering(text, x, y, color, font:, within:, showing:)
        refuse_missing_color!("draw_text", color)
        colors = text_colors!(color, showing)
        metrics = @lettering_fonts.fetch(font).metrics
        refuse_missing_characters!(text, metrics, font)
        x = column_for(x, metrics.text_width(text), within, "draw_text")
        fonts = colors.map { |each_color| @picture_fonts.fetch(picture_font_of_lettering(font, each_color)) }
        return draw_pictures_of(text, x, y, fonts.first) if fonts.length == 1

        pose = glyph_color_pose(showing)
        tiled = Text::TILE_HARDWARE_MODES.include?(@screen_mode)
        require_hud_declared_once!("draw_text") if tiled
        metrics.each_glyph_x(text) do |char, dx|
          pair = fonts.map { |each_font| each_font.picture(char) }
          if tiled
            hud_glyph_object(poses: pair, pose: pose.copy, x: x + dx, y: y)
          else
            record(Build.blit_pose(pair, pose.copy, Build.int(x + dx), Build.int(y)))
          end
        end
        nil
      end

      # draw_number in a font of a pack's pixels with the pack left out: the number drawn in the font
      # of pictures of its colour, laid out as the same font read into the build (a font of glyphs)
      # lays it out. A number that changes can show any digit, so it needs all ten. They may differ in
      # width, as an original's alphabet keeps them: each is drawn at the left of a column as wide as
      # the font's widest letter. A place the number has not reached is left empty, as a font of glyphs
      # leaves it, even where the font has a space.
      def draw_number_in_lettering(value, x, y, color, font:, digits:, within:, leading_zeros:)
        refuse_missing_color!("draw_number", color)
        refuse_missing_lettering_numerals!(font) unless DSL::Value.fixed_number(value)
        draw_number_in_pictures(value, x, y, nil, font: picture_font_of_lettering(font, color), digits: digits,
                                                  within: within, leading_zeros: leading_zeros, as_glyph_font: true)
      end

      def refuse_missing_lettering_numerals!(font)
        missing = @lettering_fonts.fetch(font).metrics.missing_characters("0123456789")
        return if missing.empty?

        raise ArgumentError,
              "draw_number: font :#{font} has no #{missing.map(&:inspect).join(', ')}. A number that changes can " \
              "show any digit, so the font needs all of 0 to 9. To fix this, add the missing letters, or draw a fixed number."
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
        return unless picture_font?(font) || lettering_font?(font)

        raise ArgumentError,
              "draw_text cannot draw a list of character codes in font :#{font}, because its letters are pictures" \
              "#{' until the game reads its pack' if lettering_font?(font)}. " \
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
      # has one (which paints over the digit that was there), else nothing. With +as_glyph_font+ it is
      # laid out as a font of glyphs lays it out: the digits may differ in size, each drawn at the left
      # of its column, and a place not reached is left empty.
      def draw_number_in_pictures(value, x, y, color, font:, digits:, within:, leading_zeros:, as_glyph_font: false)
        picture_font = @picture_fonts[font]
        refuse_color_for_picture_font!("draw_number", font, color, nil)
        cell = picture_font.cell_w
        x = column_for(x, (digits * cell) - picture_font.spacing, within, "draw_number")
        space = picture_font.picture(" ") unless as_glyph_font
        fixed = DSL::Value.fixed_number(value)
        return draw_fixed_number_in_pictures(fixed, x, y, picture_font, font, digits, leading_zeros, space) if fixed

        numerals = as_glyph_font ? ("0".."9").map { |digit| picture_font.picture(digit) } : refuse_unfit_numerals!(picture_font, font)
        blank = leading_zeros ? nil : space
        if Text::TILE_HARDWARE_MODES.include?(@screen_mode)
          require_hud_declared_once!("draw_number")
          return draw_live_number_in_sprites(value, x, y, cell, numerals, blank, digits, leading_zeros)
        end
        unless value.is_a?(Symbol) || value.is_a?(DSL::Value)
          raise ArgumentError, "draw_number draws a number: a value, a variable, or an expression. Got #{value.inspect}."
        end

        draw_live_number_in_pictures(value, x, y, font, cell, numerals, blank, digits, leading_zeros)
      end

      # A fixed number, its unreached places noughts with +leading_zeros+, else +space+ (a picture,
      # or nil to leave them empty).
      def draw_fixed_number_in_pictures(number, x, y, picture_font, font, digits, leading_zeros, space)
        text = number.to_s
        pad = [digits - text.length, 0].max
        filler = leading_zeros ? "0" : (" " if space)
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
          column = column * 2 if halved
          if poses.map { |pose| @images.fetch(pose) }.uniq.one?
            blit(poses, column, DIGIT_ROW, showing: DIGIT_SHOWN)
          else
            emit_blit_by_digit_shown(poses, column)
          end
        end
        routine
      end

      # Draws the one of +poses+ that DIGIT_SHOWN numbers, where they differ in size: a test and a
      # blit for each, since a blit that picks between pictures needs them one size.
      def emit_blit_by_digit_shown(poses, column)
        poses.each_with_index do |pose, k|
          record(Build.if_(Build.binop(:==, Build.var_ref(DIGIT_SHOWN), Build.int(k)),
                           Build.blit(pose, column.node, Build.var_ref(DIGIT_ROW))))
        end
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
