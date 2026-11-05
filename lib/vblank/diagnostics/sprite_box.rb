# frozen_string_literal: true

module VBlank
  module Diagnostics
    # ONE ENTRY OF A CONSOLE'S SPRITE TABLE, AS THE BOX IT DRAWS: which entry it is (+slot+), the
    # screen position of its top left corner in pixels (+x+, +y+, which can be below nothing or past
    # the edge, where part of it is off the screen), how wide and tall it is, and the first tile of
    # video memory it draws from. It is what the console's table says and nothing more: which sprite
    # of the game's an entry belongs to is what a build record says (Verifier#sprites), and a
    # cartridge with none has only these. Verifier#sprite_boxes reads them, each console its own way.
    SpriteBox = Data.define(:slot, :x, :y, :width, :height, :tile) do
      # A position as the table holds it, +at+, for a box +size+ long on an axis +range+ long that
      # the console wraps round: a box that runs past the end shows at the start, so it stands below
      # nothing. A box at 508 on an axis of 512, eight wide, stands at -4.
      def self.wrapped(at, size, range) = at + size > range ? at - range : at

      # Whether any of the box is on a screen +width+ by +height+.
      def on_screen?(width, height) = (x + self.width).positive? && x < width && (y + self.height).positive? && y < height
    end
  end
end
