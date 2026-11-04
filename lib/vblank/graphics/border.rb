# frozen_string_literal: true

module VBlank
  module Graphics
    # THE BORDER ROUND A GAME'S SCREEN, where a console shows a smaller screen in the middle of its
    # own: a game laid out for the Game Boy Color's 160×144, on the Advance's 240×160
    # (Console::AdvanceKit::COLOR_SCREEN). An Advance playing a Color cartridge does exactly this,
    # and fills the 40 columns either side and the 8 rows above and below with something.
    #
    # A border is a picture of the WHOLE screen; its middle is never seen, because the game's own
    # screen is drawn there. A game that gives none gets VBlank's own (#default). A game gives its
    # own with `border`, in any form `image` takes, and a picture smaller than the whole screen is
    # repeated across it, so text art of a few characters makes a pattern.
    #
    # What a border can hold is the console's to say, and here it is what the Advance's lowering
    # draws it with: sprites of sixteen colours each, one of them see-through. So a border has no
    # see-through pixel (nothing would be behind it but the backdrop) and fifteen colours at the
    # most, which is also all that it takes from the sprites' colours: one group of sixteen of
    # the console's, never a colour the game's own art could have.
    module Border
      # The most colours a border can hold.
      MOST_COLORS = 15

      # VBlank's own border, as one colour (15 bits) a pixel, row by row, for a whole screen of
      # +whole+ ([width, height]) with the game's screen +inner+ ([width, height]) in its middle.
      #
      # A dark slate with a fine diagonal grain, and round the game's screen a black line and a
      # lighter edge outside it, like the bezel round a handheld's screen: plain enough not to pull
      # the eye from the game, and marked enough to read as a frame and not as a screen left blank.
      def self.default(whole:, inner:)
        width, height = whole
        left = (width - inner[0]) / 2
        top = (height - inner[1]) / 2
        right = left + inner[0]
        bottom = top + inner[1]
        Array.new(width * height) do |at|
          x = at % width
          y = at / width
          # How far outside the game's screen this pixel is, counted in rings.
          ring = [left - x, x - (right - 1), top - y, y - (bottom - 1)].max
          if ring <= 1 then DEFAULT_LINE
          elsif ring <= 3 then DEFAULT_EDGE
          elsif ((x + y) % 4).zero? then DEFAULT_GRAIN
          else DEFAULT_FILL
          end
        end
      end

      DEFAULT_FILL = Color.rgb(4, 5, 9)
      DEFAULT_GRAIN = Color.rgb(6, 7, 12)
      DEFAULT_EDGE = Color.rgb(13, 14, 19)
      DEFAULT_LINE = Color.rgb(0, 0, 0)

      # A border the game gave (+width+ by +height+ pixels, +pixels+ packed two bytes each as
      # `image` keeps them) as a whole screen of +whole+ ([width, height]), repeated across it
      # where it is smaller.
      def self.whole_picture(width:, height:, pixels:, whole:)
        colors = pixels.unpack("v*")
        Array.new(whole[0] * whole[1]) do |at|
          x = (at % whole[0]) % width
          y = (at / whole[0]) % height
          colors[(y * width) + x]
        end
      end

      # A border that can be drawn, or a plain refusal naming what is wrong and how to fix it.
      # +transparent+ is the value a see-through pixel holds, or nil. +whole+ is the whole screen,
      # or nil where the build shows the game's screen whole and the border is not drawn (the
      # size is then not checked, since there is nothing it has to fit).
      def self.refuse_unusable!(width:, height:, pixels:, transparent:, whole:)
        colors = pixels.unpack("v*")
        if transparent && colors.include?(transparent)
          raise ArgumentError, "The border has see-through pixels. Nothing is behind a border, so every pixel " \
                               "of it must have a color. To fix this, give each see-through pixel a color."
        end
        used = colors.uniq
        if used.size > MOST_COLORS
          raise ArgumentError, "The border has #{used.size} colors. A border can have #{MOST_COLORS} colors at " \
                               "the most. To fix this, use fewer colors in the border."
        end
        return if whole.nil? || ((whole[0] % width).zero? && (whole[1] % height).zero?)

        raise ArgumentError, "The border is #{width}×#{height}. A border must be the size of the whole screen, " \
                             "#{whole.join('×')}, or a pattern that repeats across it. To fix this, make the " \
                             "border #{whole.join('×')}, or make its width divide #{whole[0]} and its height " \
                             "divide #{whole[1]}."
      end
    end
  end
end
