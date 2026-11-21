# frozen_string_literal: true

module VBlank
  module DSL
    # The game's light
    #
    # A circle the picture is drawn as it is inside, with everything outside it darkened.
    # Builder#spotlight hands one back.
    #
    # ```ruby
    # light = spotlight at: [120, 80], radius: 40, dark: 75
    # light.move_to hero.x + 8, hero.y + 8   # the lantern goes where the hero does
    # light.radius.approach! 24, 1           # and it shrinks
    # light.dark = 0                         # nothing darkened: the light is out
    # ```
    #
    # Its middle, its reach and its darkness are each a Value the game reads and changes like
    # any variable. The picture shows what they hold at the end of the frame. The light is worked
    # out again in the gap before every frame, so moving it costs a write and nothing else.
    class Spotlight
      # Built by Builder#spotlight, which declares the four and what the picture makes of them.
      def initialize(x:, y:, radius:, dark:, builder:)
        @x = x
        @y = y
        @radius = radius
        @dark = dark
        @builder = builder
      end

      # Where the middle of the light is, in screen pixels: across from the left edge, and
      # down from the top. The screen's, not a background's, so a light kept on the hero is
      # moved to where the hero's sprite is.
      attr_reader :x, :y

      # How far the light reaches from its middle, in pixels. 0 lights nothing at all.
      attr_reader :radius

      # How dark the picture is outside the light, 0 (as drawn) to 100 (black). For a light that
      # shows nothing outside it (`spotlight outside: :nothing`) it is a switch: 0 is off, 100 on.
      attr_reader :dark

      # Puts the middle of the light at a place on the screen.
      #
      # Either number may be one the game works out as it runs.
      #
      # ```ruby
      # light.move_to hero.x + 8, hero.y + 8
      # ```
      def move_to(x, y)
        @x.store! x
        @y.store! y
        self
      end

      # Gives the light a shape of the game's own, a row of the screen at a time.
      #
      # The block is handed the row, 0 at the top. It gives back how far the light reaches either
      # side of its middle on that row, or the row's two edges, `[left, right]`: the columns from
      # left up to, and not including, right. The circle is the shape a light has until it is
      # given one.
      #
      # ```ruby
      # light.shape { |row| 40 - (row - light.y).abs }               # a diamond
      # light.shape { |row| light.circle((row - 1).clamp(0, 159)) }  # each row the circle of the row above
      # ```
      #
      # The rows are worked out in the gap before each frame, from what the game's numbers hold
      # then. A shape works its rows out and does nothing else: it may declare variables of its
      # own and change them, and read the game's numbers and tables, but it cannot change a
      # variable of the game's, read a list or the buttons, call a routine, play a sound or draw.
      # That is what lets the console skip the rows on a frame nothing they read has changed.
      def shape(&block)
        @builder.record_light_shape(self, &block)
        self
      end

      # How far this light's circle reaches either side of its middle on a row of the screen.
      #
      # The circle is the shape the light has until it is given one, so a Spotlight#shape can
      # build on it. Up to a radius of 150 it is the midpoint circle the console's own games draw.
      #
      # ```ruby
      # light.shape { |row| light.circle(row) - 4 }   # the circle, four pixels narrower each side
      # ```
      def circle(row) = @builder.light_circle(self, row)

      # Shows the light as it stands on the picture being drawn, not the next one.
      #
      # A change to the light otherwise shows a picture later, like a sprite's place, because its
      # rows are worked out in the gap before a frame. Some games hand their light to the display
      # while the picture is drawn, so a change shows at once: an iris that opens on the frame it
      # is asked for. This is how a game that works the same way asks for it.
      #
      # ```ruby
      # light.radius = 4
      # light.show_now
      # ```
      #
      # On the console the rows are worked out where this is reached. Early in a pass that is
      # still the gap before the picture, and the whole picture shows them; once the display has
      # started drawing, only the lines it reaches after they are worked out do, so call it
      # early. A light that has not changed costs nothing.
      def show_now
        @builder.show_light_now
        self
      end
    end
  end
end
