# frozen_string_literal: true

module VBlank
  module DSL
    # What `screen_spot :rooms, point, seen_by: eye` hands back: where one point of a place lands
    # on the screen as the viewer sees it, worked out as the game runs. A game uses it to find the
    # rectangle a doorway covers on the screen, and draws the room beyond held to that.
    #
    #   corner = screen_spot :rooms, door_corner, seen_by: eye
    #   left = corner.x if corner.x < left
    #
    # Each is a Value the game reads like any variable:
    #
    #   x, y      the pixel the point lands on, across and down: the first pixel whose middle is at
    #             or past the point, as a face's corner is counted. A point well off the screen
    #             lands off it, below nought or past the edge.
    #   behind?   true when the point is behind the viewer or nearer than the near limit. Then it
    #             lands nowhere, and x and y are both nought.
    class ScreenSpot
      # The answers it keeps, each in a variable of its own.
      ANSWERS = %i[x y behind].freeze

      # +answers+ is a Value for each of ANSWERS.
      def initialize(answers)
        @answers = answers
      end

      def x = @answers.fetch(:x)
      def y = @answers.fetch(:y)

      # A Condition: true when the point lands nowhere on the screen, being behind the viewer.
      def behind? = @answers.fetch(:behind) == 1
    end
  end
end
