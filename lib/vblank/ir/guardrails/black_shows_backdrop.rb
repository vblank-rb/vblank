# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A warning about a background tile drawn from colours alone, with black pixels, in a game
        # whose backdrop is not black:
        #
        # > The picture :<name> is a background tile with black pixels. The tile has no place
        # > numbers, so its black pixels show the backdrop. The backdrop of this game is not black,
        # > so these pixels are not black on the screen. To keep them black, give the picture
        # > `places:` and a `colors:` list with black in it. For example:
        # > `colors: [:transparent, :black, :red]`. Place 0 shows the backdrop.
        #
        # There is one warning for each such picture, at the picture's own line. A picture given
        # `places:` keeps black solid, since place 0 is the one that shows the backdrop. A picture
        # that only a sprite shows is not a tile, and is left alone.
        #
        #--
        # Black pixels in a tile, over a backdrop of another colour.
        #
        # A tile has no mark of its own for "nothing here", so the backdrop colour, black, is what
        # marks it (Assets::Image#tile_see_through_at?): a black pixel of a picture with no place
        # numbers is see-through, even where the picture marks other pixels `:transparent` and even
        # when it is drawn with a named list of colours. Only art that came with its places keeps
        # black solid. Every backend asks that one question, so the game looks the same on each, and
        # what it looks like is the backdrop's colour in place of the black the author drew. Black
        # backdrop, or none: there is nothing to see. The warning only reads the program, so it
        # changes no cartridge.
        #++
        class BlackShowsBackdrop
          NAME = :black_shows_backdrop
          PLAIN_NAME = "black tiles over a backdrop of another color"

          # Every colour channel of a colour the console draws: the low 15 bits.
          COLOR_BITS = 0x7FFF

          def detect(program)
            return [] unless program.walk.any? { |node| backdrop_not_black?(node) }

            named = program.walk.select { |node| node.kind == :background }.flat_map(&:tiles).uniq
            program.walk.select { |node| node.kind == :bitmap && named.include?(node.name) && shows_backdrop?(node) }
                   .map { |picture| Finding.new(check: NAME, severity: :warning, node: picture, message: message(picture.name)) }
          end

          private

          def backdrop_not_black?(node)
            node.kind == :screen && node.backdrop.is_a?(Integer) && (node.backdrop & COLOR_BITS).nonzero?
          end

          # Does the picture draw a black pixel that a tile shows the backdrop through?
          def shows_backdrop?(node)
            image = Assets::Image.of(node)
            image.places.nil? && (0...(image.width * image.height)).any? { |at| image.drawn_at?(at) && image.tile_see_through_at?(at) }
          end

          def message(name)
            "The picture :#{name} is a background tile with black pixels. The tile has no place numbers, so its " \
              "black pixels show the backdrop. The backdrop of this game is not black, so these pixels are not " \
              "black on the screen. To keep them black, give the picture `places:` and a `colors:` list with " \
              "black in it. For example: `colors: [:transparent, :black, :red]`. Place 0 shows the backdrop."
          end
        end
      end
    end
  end
end
