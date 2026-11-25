# frozen_string_literal: true

module VBlank
  class Builder
    # Canvases
    #
    # A canvas is a picture your game draws into while it runs, using colour names: a pixel, a
    # rectangle, a picture, a letter, some text or a number. Use one for what the game works out as
    # it goes, such as a name typed a letter at a time, a meter or a map of where the player has
    # been. A background shows it, or a sprite uses it as its picture.
    #
    # ```ruby picture=once frames=90
    # VBlank.game "CANVAS", consoles: %i[gba] do
    #   screen :tiled, backdrop: rgb(3, 4, 7)
    #   colors :ink,
    #          %i[transparent white yellow red]
    #   board = canvas :board, width: 96,
    #                  height: 32, colors: :ink
    #   background :sign, tiles: :board,
    #                     map: board.cells
    #   board.draw_text "ENERGY", 8, 4, :white
    #   board.fill_rect 8, 18, 80, 8, :red
    #   energy = 0
    #   game_loop do
    #     energy += 1 if energy < 80
    #     # a meter that fills as the game runs
    #     board.fill_rect 8, 18, energy, 8,
    #                     :yellow
    #   end
    # end
    # ```
    #--
    # See DSL::Canvas. It is the friendly side of `tiles ..., from: list` and `image ..., from:
    # list`, which hand the game a list to pack pixels into itself; a canvas keeps that list.
    #++
    module Canvases
      # The characters a canvas can draw a letter of: every code a game writes as text.
      LETTER_CODES = 128  # :nodoc:

      # FontTables: one font, as the tables a canvas reads a letter out of while the game
      # runs — each character's rows of lit pixels, and its width.
      FontTables = Data.define(:rows, :widths, :height, :widest, :spacing)  # :nodoc:

      # Declares a picture the game draws into while it runs, and returns it to draw with.
      #
      # By default a background shows the canvas. Other keys given here are ordinary tiles beside
      # it in the same set, such as a box's frame. With `as: :sprite` it is a sprite's picture
      # instead, and then its size must be one the console draws a sprite at.
      #
      # ```ruby
      # board = canvas :board, width: 208, height: 32, colors: :ink
      # background :box, tiles: :board, map: board.cells
      # board.fill_rect 4, 4, 40, 8, :red
      # ```
      #
      # * `name` - the canvas's name, as a symbol.
      # * `width:` and `height:` - its size in pixels, each a whole number of tiles (a multiple of 8).
      # * `colors:` - the colours it draws with: a `colors` list by name, or the colours
      #   themselves, with the see-through one first.
      # * `as:` - `:tiles` for a background to show it, or `:sprite` for a sprite's picture.
      # * `fast:` - `true` or `false` to choose whether its pixels sit in the quick memory.
      def canvas(name, width:, height:, colors:, as: :tiles, fast: nil, **fixed)
        refuse_bad_canvas!(name, width, height, as)
        bytes = width * height / 2
        list_name = Messages::MadeNames.make(:canvas_part, canvas: name, part: :pixels)
        # Made full at power-on, so every byte is there to write by number from the start.
        at_boot(Build.list_new(list_name, bytes, width: :byte, fast: fast, full_of: 0))
        list = DSL::List.new(self, list_name)
        run = if as == :sprite
                image(name, from: list, width: width, height: height, colors: colors)
              else
                tiles(name, { from: list, count: (width / 8) * (height / 8), colors: colors }.merge(fixed))
              end
        DSL::Canvas.new(self, name: name, list: list, run: run, width: width, height: height,
                              colors: tile_run_colors(name, colors, what: "canvas"))
      end

      # A font a canvas draws letters of, as tables read while the game runs. Made once per
      # font however many canvases use it.
      # Asked by a `canvas` while it builds its words; documented on `canvas`.
      def canvas_font_tables(font)  # :nodoc:
        @canvas_font_tables ||= {}
        @canvas_font_tables[font] ||= begin
          face = canvas_font(font)
          rows = (0...LETTER_CODES).flat_map do |code|
            glyph = face.glyph(code.chr)
            Array.new(face.height) { |row| glyph ? glyph[row] : 0 }
          end
          widths = (0...LETTER_CODES).map { |code| face.glyph(code.chr) ? face.glyph_width(code.chr) : 0 }
          FontTables.new(
            rows: table(Messages::MadeNames.make(:canvas_font, font: font, part: :rows), rows, width: :half, signed: false),
            widths: table(Messages::MadeNames.make(:canvas_font, font: font, part: :widths), widths, width: :byte,
                                                                                                     signed: false),
            height: face.height, widest: face.width, spacing: face.spacing
          )
        end
      end

      # The font named +font+.
      # Asked by a `canvas` while it builds its words; documented on `canvas`.
      def canvas_font(font) = IR::FontTable.of(@program).get(font)  # :nodoc:

      # A declared picture's size, [width, height].
      # Asked by a `canvas` while it builds its words; documented on `canvas`.
      def image_size(image)  # :nodoc:
        @images.fetch(image) do
          raise ArgumentError, "there is no image named :#{image}. Define it first with `image :#{image}, ...`."
        end
      end

      # A declared picture's pixels, row by row: each one's colour, or nil where it is see-through.
      # A pixel in a colour read from the data pack as the game starts is the marker it is
      # (IR::StartFile), which the canvas's own list of such colours holds too: masked to fifteen
      # bits it would be a colour that is no colour of the list.
      # Asked by a `canvas` while it builds its words; documented on `canvas`.
      def image_pixels(image)  # :nodoc:
        image_size(image)
        node = @program.walk.find { |each| each.kind == :bitmap && each.name == image }
        picture = IR::Assets::Image.of(node)
        (0...(picture.width * picture.height)).map do |i|
          next nil unless picture.drawn_at?(i)

          IR::StartFile.marker?(picture.raw_at(i)) ? picture.raw_at(i) : picture.color_at(i)
        end
      end

      private

      def refuse_bad_canvas!(name, width, height, as)
        unless %i[tiles sprite].include?(as)
          raise ArgumentError, "canvas :#{name} was given `as: #{as.inspect}`. It is :tiles (the default, a " \
                               "background shows it) or :sprite."
        end
        return if [width, height].all? { |side| side.is_a?(Integer) && side.positive? && (side % 8).zero? }

        raise ArgumentError, "canvas :#{name} is #{width.inspect}x#{height.inspect}. Each side must be a whole " \
                             "number of tiles, so a multiple of 8. To fix this, round each side up to a multiple of 8."
      end
    end
  end
end
