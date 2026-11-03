# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN ON A SUPER FX CARTRIDGE: what Paint does differently there.
          #
          # The picture is kept where Paint keeps it, laid out the same way (896 tiles of eight bits a
          # pixel, in the order they are shown), but in the Super FX's own RAM, $70:0000 to $70:DFFF,
          # rather than the last bank of work RAM. The console's processor can read and write that RAM
          # whenever the chip is stopped, so every one of Paint's routines paints there unchanged.
          #
          # Each tile's generation (Paint's GENERATIONS, a byte a tile) is in the chip's RAM too, just
          # past the picture, because a routine run on the chip that paints (ChipColumns) has to know
          # whether a tile it is about to paint is of this generation, and make it ready if it is not,
          # and the chip cannot see work RAM. Both processors read and write the same bytes, so
          # neither copies them for the other. What else Paint keeps beside the picture (the map, the
          # runs to send) stays in work RAM with the game's far places.
          #
          # WHY NOT THE CHIP'S OWN PLOT. The Super FX has an instruction that plots a pixel into its
          # RAM, laid out as the console's tiles. But it lays the tiles out a column at a time, for a
          # picture 128, 160 or 192 pixels high, or in four squares of 128 (its "OBJ" layout); none of
          # them is a screen 224 high in rows of 32 tiles, which is how Paint, its runs to video RAM
          # and its map keep the picture, and the four squares would need 60K, leaving no room for
          # the chip's numbers. So the chip paints the way Paint does, a row of a tile's eight planes
          # at a time, through a mask of the one pixel.
          #
          # A clear writes nothing on either cartridge (Paint moves the screen on a generation), so
          # the chip has nothing of the clear to do. The copy to video RAM is Paint's
          # rt_paint_upload, a blank at a time with the screen on, from the chip's RAM rather than
          # work RAM.
          #
          # THE CHIP'S NUMBERS ARE PAST THOSE: the rest of its 64K, whatever the game's screen is,
          # is where a routine run on the chip finds the variables it uses (ChipCode).
          module ChipPaint
            COPY = Console::SNESHardware::GSU_RAM_BANK << 16
            GENERATIONS = COPY + Paint::COPY_BYTES
            NUMBERS = GENERATIONS + Paint::TILES
            NUMBERS_END = COPY + 0x1_0000
          end
        end
      end
    end
  end
end
