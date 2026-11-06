# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # WHAT A GAME OF BIG PIXELS (`screen :bitmap, pixel_size: 2`) CANNOT HAVE YET.
        #
        # The game draws a small picture and the console shows it bigger. On the Advance the painted
        # screen is drawn through a background that can resize, told to read half a pixel for each
        # pixel it shows (Backends::GBA::Drawing#emit_bigger_pixels), so everything drawn INTO the
        # picture is shown right. What is done to the picture as it is shown is counted in the
        # console's own pixels, not the game's, and none of it is made to count in the game's yet:
        #
        # - the camera (and `shake_screen`, which moves it) moves the window over the picture, and on
        #   the Advance it would show the part of the picture past the small one's edge, which the
        #   interpreter shows as the backdrop;
        # - `pixelate` makes blocks of the console's pixels, which would be half the game's;
        # - a light and a fade held to a rectangle are cut by the display's windows, whose edges are
        #   the console's pixels;
        # - a sprite over the painted picture (`over_picture: true`) is the console's own and is
        #   not shown bigger;
        # - `read_scanline` counts the console's lines;
        # - a game shown in a border is already moved inside the console's screen.
        #
        # So each is refused by name, on every console, rather than drawn at the wrong size.
        class BiggerPixelsNotMadeYet
          NAME = :bigger_pixels_not_made_yet
          PLAIN_NAME = "a part of a game that big pixels do not make yet"

          def detect(program)
            return [] unless program.kind == :program && program.pixel_size.to_i > 1

            border = program.described_console.bordered?
            program.walk.filter_map do |node|
              what = (border && node.kind == :program) ? "a border round the screen" : not_made_yet(node)
              next unless what

              Finding.new(check: NAME, severity: :error, node: node, message: message(what, program.pixel_size))
            end
          end

          private

          def not_made_yet(node)
            case node.kind
            when :camera then "the camera (`camera` or `shake_screen`)"
            when :pixelate then "`pixelate`"
            when :shade_outside, :show_light_now then "a light (`spotlight`, `iris_out` or `iris_in`)"
            when :fade then "a fade held to a rectangle (`inside:` or `outside:`)" if node.area
            when :object then "a sprite over the picture (`over_picture: true`)" if node.over_picture
            when :read_scanline then "`read_scanline`"
            end
          end

          def message(what, size)
            "This game says `pixel_size: #{size}`, and #{what} is not made yet for big pixels. To fix this, " \
              "remove it from the game, or remove pixel_size:."
          end
        end
      end
    end
  end
end
