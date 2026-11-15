# frozen_string_literal: true

module VBlank
  module IR
    # WHICH STATEMENTS PAINT OVER THE WHOLE SCREEN, asked two ways. The bookkeeping that tells
    # a bitmap sprite it is off the picture (Builder::Sprites#finalize_sprite_clears) needs to
    # know every pixel went (#covers_screen?). The warning about a sprite cleared every frame
    # (Guardrails::Checks::SpriteClearedEachFrame) needs only to know the fill is a screen in
    # size (#screen_sized?), since a shaking full-screen fill is the same mistake.
    #
    # A `clear_screen` is the plain way to do it, and both count it. A filled rectangle counts
    # only where the numbers each question reads are written in the program: one the game
    # works out as it runs can come to anything.
    #
    # Neither asks about an `inside` area, which holds a clear or a fill to that area. The
    # caller that needs that asks it.
    module WholeScreen
      # The fills whose place and size can say they cover the screen. A `draw_rect_at` reads its
      # numbers as the game runs, but a number written in the program is still known.
      RECT_FILLS = %i[fill_rect dma_fill_rect draw_rect_at].freeze

      # Whether +node+ provably paints every pixel of a screen +width+ by +height+: a clear, or a
      # fill whose place and size are written in the program, from the top left corner (or past
      # it) to the far edges (or past them). The part hanging off the screen is clipped on every
      # backend. What the sprites' bookkeeping asks: counting a fill that leaves pixels would
      # leave a sprite there that no longer rubs itself out.
      def self.covers_screen?(node, (width, height))
        return true if node.kind == :clear_screen
        return false unless RECT_FILLS.include?(node.kind)

        x, y, w, h = [node.x, node.y, node.w, node.h].map { |operand| KeptWidths.written_number(operand) }
        return false if [x, y, w, h].include?(nil)

        x <= 0 && y <= 0 && x + w >= width && y + h >= height
      end

      # Whether +node+ paints a screen's size of pixels wherever it is placed: a clear, or a
      # fill whose size is written in the program and is as big as the screen, at any place,
      # one the game works out included. What the warning about a sprite cleared every frame
      # asks: such a fill wipes all or nearly all of the field under the sprite.
      def self.screen_sized?(node, (width, height))
        return true if node.kind == :clear_screen
        return false unless RECT_FILLS.include?(node.kind)

        w = KeptWidths.written_number(node.w)
        h = KeptWidths.written_number(node.h)
        !w.nil? && !h.nil? && w >= width && h >= height
      end
    end
  end
end
