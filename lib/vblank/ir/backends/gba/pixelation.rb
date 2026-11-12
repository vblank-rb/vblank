# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # WHO IS DRAWN IN BLOCKS when the game pixelates.
        #
        # The console keeps the SIZE of a block in one register, and whether a thing is
        # drawn in blocks at all as a switch on the thing: one bit of a background's
        # control register, and one bit of the first word of a sprite's entry in the table
        # the console draws sprites from. A block of one pixel is the picture as drawn, so
        # a switch left on costs nothing while the size is one — which is what lets the
        # switches be settled here, as the cartridge is built, and never written again.
        # All that is written while the game runs is the size.
        #
        # LEAVING PART OF THE PICTURE AS DRAWN IS THEREFORE FREE, where a fade placed in the
        # stack is not: `pixelate 8, under: :ui` simply leaves the switch off for everything
        # in :ui and in front of it. The price is that there is one such place in a game,
        # since a second would mean changing the switches as the game runs (see Blocks).
        #
        # Nothing to do — and not one emitted byte different — for a program that never
        # pixelates.
        class Pixelation
          include Console::Hardware

          def initialize(picture, program)
            places = Blocks.places(program)
            raise LoweringError, Blocks.several_places_message(places) if places.size > 1

            @pixelates = !places.empty?
            @kept = places.first ? IR::Stacking.at_or_above(picture, places.first).map(&:name) : []
            @keeps_sprites = Blocks.keeps_sprites?(program, LoweringError)
            @bar_in_blocks = Blocks.bar_in_blocks!(program, LoweringError)
          end

          # Does the program pixelate at all?
          def pixelates? = @pixelates

          # The bit that goes into the control register of the background +name+.
          def background_bit(name) = in_blocks?(name) ? BG_MOSAIC : 0

          # ...and of the status bar +name+, which is in blocks only where the game puts it there
          # (`status_bar: true`). The display counts a block's lines from the top of the screen
          # whichever layers it shows, so a block that starts above the bar's window shows on its
          # rows inside it the bar's layer read at the block's first row, above the bar's map, as
          # the interpreter draws it (Reference#paint_status_bar_rows).
          def bar_bit(name) = @bar_in_blocks ? background_bit(name) : 0

          # ...and the one that goes into the first word of the sprite +name+'s table entry: never
          # set in a game that leaves its sprites as drawn (`sprites: false`).
          def sprite_bit(name) = !@keeps_sprites && in_blocks?(name) ? OBJ_MOSAIC : 0

          private

          def in_blocks?(name) = @pixelates && !@kept.include?(name)
        end
      end
    end
  end
end
