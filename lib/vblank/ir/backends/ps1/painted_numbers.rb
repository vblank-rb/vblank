# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A painted screen kept as colour numbers, for a game that fades or tints it. The interpreter fades
        # a painted screen as it is shown and changes nothing drawn (Reference::Framebuffer#shown), so the
        # picture comes back whole when the fade lifts. The PlayStation's pages hold whole colours, and its
        # graphics chip blends by rules of its own that round differently from the interpreter's
        # (Framebuffer#walked_toward, #mixed). What it does exactly is read a picture through a colour
        # table. So such a game draws a number in every pixel in place of the colour, and the page it drew
        # is copied onto the screen through a table of 256 colours as each pass ends
        # (Runtime::Paint's rt_paint_numbers_shown), the table walked by the fade or tint in force as a
        # screen drawn from tiles walks its tables (Runtime::Colors).
        #
        # A number is a colour to the chip: it is drawn by the same fills and pictures as a colour. Number n
        # is the halfword n, the number in its low byte, and the copy reads the page as a picture of a byte a
        # pixel, two bytes a halfword (TextureMemory's 8 bits), at half the width it draws. The chip's rule
        # for which texel a pixel shows (PS1::PolygonFill) puts pixel x of a piece at byte 2x, the low byte,
        # and never 2x + 1 (Beetle PSX measured: a screen of 256 numbers shown exactly). So the high byte is
        # never read, and a picture drawn by number can mark its pixels drawn in the halfword's top bit
        # (Console::PS1Hardware::TEXEL_DRAWN), and a fill can drop it, with no number changed. So
        # MOST_COLORS numbers, one an entry of the table.
        #
        # Number 0 is black: video RAM starts at nought, and the interpreter's screen starts black.
        class PaintedNumbers
          TABLE_COLORS = TextureMemory::TABLE_COLORS.fetch(8)
          MOST_COLORS = TABLE_COLORS

          def initialize
            @numbers = { 0 => 0 }
          end

          # The colour a page drawn by number holds for +color+ (15 bits), given a number the first time.
          def halfword_for(color) = @numbers[color & 0x7FFF] ||= @numbers.length

          # Whether the game draws more colours than there are numbers.
          def too_many? = @numbers.length > MOST_COLORS

          # The table the page is read through: each number's colour as the chip reads it, and nought
          # (see-through) for a number no colour has.
          def table_entries
            colors = @numbers.invert
            Array.new(TABLE_COLORS) do |entry|
              color = colors[entry]
              color ? TextureMemory.texel_for_color(color) : 0
            end
          end
        end
      end
    end
  end
end
