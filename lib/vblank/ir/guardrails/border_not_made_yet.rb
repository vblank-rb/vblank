# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # WHAT A BUILD THAT SHOWS THE GAME'S SCREEN IN A BORDER DOES NOT MAKE YET (a game laid out for
        # the Game Boy Color, built for the Advance: Console::AdvanceKit::COLOR_SCREEN).
        #
        # The Advance's build moves the game's picture to the middle of its screen and draws the
        # border with sprites in front of it (Backends::GBA::BorderSprites), and it keeps the
        # display's first window for the game's screen, so a fade or a tint never darkens the
        # border. Each thing below would need a part of the display that build already uses, or
        # would need moving to the middle too, and none of that is made yet:
        #
        # - a status bar and a light use the display's windows, and the light's circle is drawn a
        #   row at a time from the top of the screen;
        # - a fade held to a rectangle uses the first window, and one held under a layer uses the
        #   sprite window;
        # - a background bent row by row is fed a row at a time from the top of the screen too;
        # - a background or a screen that turns has its corner worked out from the whole screen's;
        # - `pixelate` draws blocks counted from the whole screen's corner, which the game's
        #   screen's is not on for a block of sixteen;
        # - `hide_sprites` switches off every sprite, the border's among them;
        # - `read_scanline` counts the lines of the whole screen.
        #
        # So each is refused by name, rather than drawn somewhere the game did not put it. The
        # Color refuses most of these for a lack of hardware, so a game written for the Color meets
        # only the status bar, the bent rows and `hide_sprites` here.
        class BorderNotMadeYet
          NAME = :border_not_made_yet
          PLAIN_NAME = "a part of a game that a build with a border does not make yet"

          def detect(program)
            console = program.described_console
            return [] unless console.bordered?

            program.walk.filter_map do |node|
              what = not_made_yet(node) or next

              Finding.new(check: NAME, severity: :error, node: node, message: message(what, console))
            end
          end

          private

          def not_made_yet(node)
            case node.kind
            when :background then "a status bar (`status_bar :#{node.name}`)" if node.bar?
            when :shade_outside, :show_light_now then "a light (`spotlight`, `iris_out` or `iris_in`)"
            when :fade then held_fade(node)
            when :scroll_rows then "a background bent row by row (`scroll_each_row`)"
            when :affine_background then "a background that turns or resizes (`rotate` or `scale`)"
            when :screen then "`screen :rotozoom`" if node.mode == :rotozoom
            when :pixelate then "`pixelate`"
            when :hide_sprites then "`hide_sprites`"
            when :read_scanline then "`read_scanline`"
            end
          end

          def held_fade(node)
            return "a fade held to a rectangle (`inside:` or `outside:`)" if node.area
            return "a fade under a layer (`under: :#{node.under}`)" if node.under

            nil
          end

          def message(what, console)
            "This game is built for the #{console.title}. That build shows the game's " \
              "#{console.screen_width}×#{console.screen_height} screen in a border, and #{what} is not made yet " \
              "for such a build. To fix this, remove it from the game, or do not build the game with the border."
          end
        end
      end
    end
  end
end
