# frozen_string_literal: true

module VBlank
  module DSL
    # Where a point of a place lands on the screen
    #
    # `screen_spot` hands one back: where one point of a place lands on the screen as a viewer
    # sees it, worked out as the game runs. A game uses it to find the rectangle a doorway covers
    # on the screen, and then draws the room beyond inside that rectangle.
    #
    # ```ruby
    # corner = screen_spot :rooms, door_corner, seen_by: eye
    # left = corner.x if corner.x < left
    # ```
    #
    # Each answer is a Value the game reads like any variable.
    class ScreenSpot
      # The answers it keeps, each in a variable of its own.
      ANSWERS = %i[x y behind].freeze # :nodoc:

      # +answers+ is a Value for each of ANSWERS.
      def initialize(answers)
        @answers = answers
      end

      # The pixel across the screen that the point lands on.
      #
      # It is the first pixel whose middle is at or past the point, counted as a face's corner is.
      # A point well off the screen lands off it, below 0 or past the edge. A point behind the
      # viewer (#behind?) lands at 0.
      def x = @answers.fetch(:x)

      # The pixel down the screen that the point lands on, counted as #x is.
      def y = @answers.fetch(:y)

      # A test that is true when the point lands nowhere on the screen.
      #
      # That is when the point is behind the viewer, or nearer than the nearest it draws. Then #x
      # and #y are both 0.
      #
      # ```ruby
      # draw_rect_at corner.x, corner.y, 4, 4, :red unless corner.behind?
      # ```
      def behind? = @answers.fetch(:behind) == 1
    end
  end
end
