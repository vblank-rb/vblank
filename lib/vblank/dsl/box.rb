# frozen_string_literal: true

module VBlank
  module DSL
    # Boxes for collision tests
    #
    # A box is a rectangle on the screen, a top-left corner and a size, made with `box`. It
    # draws nothing: it is a region to test a sprite or another box against, with
    # Bounds#overlaps? and the screen-edge tests. Each of its numbers can be a number written
    # in the game or one the game keeps, so one box can follow a moving thing as easily as it
    # marks a fixed wall.
    #
    # ```ruby
    # wall = box 0, 140, 240, 20
    # bat  = box bat_x, 150, 32, 4
    # speed = -speed if ball.overlaps?(bat)
    # ```
    #
    # Its edges read back as numbers to compute with: `right` is `x + w` and `bottom` is
    # `y + h`.
    class Box
      include Bounds # gains overlaps? from left / top / right / bottom

      # The box's left edge, top edge, width and height, each as a number to compute with.
      attr_reader :x, :y, :w, :h

      # A box is exactly its rectangle — its collision edges are its corner and size,
      # with no transparent margin to trim (unlike a sprite, whose box hugs its art).
      alias left x
      alias top y

      # @param builder [Builder] the build its coordinates belong to
      # @param x, y, w, h [Integer, Symbol, Value] corner and size, each an operand
      #   the expression DSL understands
      def initialize(builder, x, y, w, h)
        @builder = builder
        @x = coerce(builder, x)
        @y = coerce(builder, y)
        @w = coerce(builder, w)
        @h = coerce(builder, h)
      end

      # The build these coordinates belong to, which Bounds asks for the screen.
      def collision_builder = @builder # :nodoc:

      # The box's right edge, `x + w`, as a number to compute with.
      def right
        @x + @w
      end

      # The box's bottom edge, `y + h`, as a number to compute with.
      def bottom
        @y + @h
      end

      private

      # Wrap any operand — a number, a :variable, or an expression Value — as a Value,
      # so every field of a box speaks the expression DSL regardless of how it came in.
      def coerce(builder, operand)
        Value.new(builder, Value.node_for(operand))
      end
    end
  end
end
