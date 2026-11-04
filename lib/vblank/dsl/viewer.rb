# frozen_string_literal: true

module VBlank
  module DSL
    # What `viewer :eye, at: [0.0, 0.0, -4.0]` hands back: the spot a place is seen from, and which
    # way it faces (`draw_place :cube, seen_by: eye`).
    #
    # Which way it faces is three arrows, each of length one and each square to the others: RIGHT,
    # UP and AHEAD. A viewer that has not been turned faces along the place's own arrows: right is
    # x, up is y and ahead is z. Together the three are what graphics books call an orientation
    # matrix; nothing here needs the word.
    #
    # The viewer is twelve variables (its spot, then its three arrows), so a later change can move
    # and turn it as the game runs.
    class Viewer
      PARTS = IR::PlaceDrawing::VIEWER_PARTS

      # How far from length one an arrow given to `facing:` may be, and how far from square to
      # the others.
      SLACK = 0.01

      def initialize(name)
        @name = name
      end

      attr_reader :name

      # The variable that holds +part+ of this viewer (one of PARTS).
      def variable(part) = Messages::MadeNames.make(:viewer_part, viewer: @name, part: part)

      # Every variable, in PARTS order.
      def variables = PARTS.map { |part| variable(part) }

      # The twelve starting numbers for +at+ and +facing+ (a Hash of :right, :up and :ahead, each
      # three numbers), in PARTS order, refused in plain words when they are not a spot and three
      # square arrows of length one.
      def self.starting_numbers(name, at, facing)
        refuse_bad_spot!(name, at)
        arrows = %i[right up ahead].map { |arrow| facing.fetch(arrow) { refuse_bad_facing!(name, "it has no #{arrow}:") } }
        refuse_bad_arrows!(name, arrows)
        at.map(&:to_f) + arrows.flatten.map(&:to_f)
      end

      def self.refuse_bad_spot!(name, at)
        return if at.is_a?(Array) && at.length == 3 && at.all? { |number| number.is_a?(Numeric) && number.abs <= Place::FURTHEST }

        raise ArgumentError, "viewer :#{name} was given at: #{at.inspect}. A viewer stands at a spot of three " \
                             "numbers, across, up and ahead, each from -#{Place::FURTHEST} to #{Place::FURTHEST}. " \
                             "To fix this, give at: [x, y, z]."
      end

      def self.refuse_bad_arrows!(name, arrows)
        unless arrows.all? { |arrow| arrow.is_a?(Array) && arrow.length == 3 && arrow.all?(Numeric) }
          refuse_bad_facing!(name, "an arrow is not three numbers")
        end
        refuse_bad_facing!(name, "an arrow is not of length one") unless arrows.all? { |arrow| (dot(arrow, arrow) - 1).abs <= SLACK }
        square = arrows.combination(2).all? { |one, other| dot(one, other).abs <= SLACK }
        refuse_bad_facing!(name, "two of its arrows are not square to each other") unless square
      end

      def self.refuse_bad_facing!(name, what)
        raise ArgumentError, "viewer :#{name} was given a facing: that cannot be: #{what}. A facing is three " \
                             "arrows, right:, up: and ahead:. Each is three numbers of length one, and each is " \
                             "square to the other two. To fix this, leave facing: out, or give arrows like " \
                             "right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1]."
      end

      def self.dot(one, other) = one.zip(other).sum { |a, b| a * b }

      private_class_method :refuse_bad_spot!, :refuse_bad_arrows!, :refuse_bad_facing!, :dot
    end
  end
end
