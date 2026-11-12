# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # THE BLOCKS A PICTURE IS SHOWN IN when a program pixelates: what every backend has
      # to agree on, kept where both read it so they cannot come to different answers.
      #
      # HOW BIG a block can be is the display's: it keeps the size in a few bits, so there
      # is a biggest one, and a size asked for past either end stops at that end. It is
      # written here, since every backend has to stop at the same size, and the Advance's
      # display keeps the same biggest one (MOSAIC_LARGEST).
      #
      # WHERE the blocks stop is one place for a whole program. A statement can leave a
      # layer, and everything in front of it, as drawn. A display keeps "in blocks" as a
      # switch on each thing in the picture rather than as a line it can move, so a
      # program gets one such line, settled before it runs. One backend could draw two;
      # the other could not, so neither does.
      module Blocks
        LARGEST = 16

        module_function

        # +asked+ held to the sizes there are: 1 is the picture as drawn.
        def size(asked) = asked.clamp(1, LARGEST)

        # Every place +program+ puts its blocks: nil for the whole picture, or the name of
        # a layer left as drawn. None for a program that never pixelates, and more than
        # one for a program no backend runs (see #several_places_message).
        def places(program)
          program.walk.select { |node| node.kind == :pixelate }.map(&:under).uniq
        end

        def several_places_message(places)
          said = places.map { |place| place ? "under :#{place}" : "over the whole picture" }.join(" and ")
          "This program pixelates #{said}. A program pixelates from one place in the stack, " \
            "because which things are drawn in blocks is settled once, before it runs. To fix " \
            "this, give every pixelate the same place."
        end

        # WHETHER THE SPRITES ARE LEFT AS DRAWN, which is one choice for a whole program for
        # the same reason as the place: each sprite's switch is settled before it runs. Every
        # choice +program+'s `pixelate` statements make: true where the backgrounds alone are
        # put into blocks. None for a program that never pixelates, and both for a program no
        # backend runs (see #mixed_sprites_message).
        def sprite_choices(program)
          program.walk.select { |node| node.kind == :pixelate }.map { |node| node.keeps_sprites == true }.uniq
        end

        # Does +program+ pixelate its backgrounds alone, every sprite left as drawn? Raises
        # +error+ for a program that chooses both ways.
        def keeps_sprites?(program, error)
          choices = sprite_choices(program)
          raise error, mixed_sprites_message if choices.size > 1

          choices == [true]
        end

        def mixed_sprites_message
          "This program pixelates with `sprites: false` in one place and with the sprites in blocks " \
            "in another. The build sets which things are in blocks one time, before the game runs. " \
            "To fix this, give every `pixelate` the same `sprites:`."
        end

        # WHETHER A STATUS BAR IS IN BLOCKS, one choice for a whole program for the same reason:
        # true where `pixelate ..., status_bar: true` puts it in them, in the one grid every
        # background's blocks are in (Reference#paint_status_bar_rows). Raises +error+ for a
        # program that chooses both ways.
        def bar_in_blocks!(program, error)
          choices = program.walk.select { |node| node.kind == :pixelate }.map { |node| node.bar_in_blocks == true }.uniq
          raise error, mixed_bar_message if choices.size > 1

          choices == [true]
        end

        def mixed_bar_message
          "This program pixelates with `status_bar: true` in one place and with the status bar as drawn " \
            "in another. The build sets which things are in blocks one time, before the game runs. " \
            "To fix this, give every `pixelate` the same `status_bar:`."
        end
      end
    end
  end
end
