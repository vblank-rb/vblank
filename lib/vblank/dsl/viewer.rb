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
    # The viewer is twelve variables (its spot, then its three arrows), each a fraction, which the
    # game moves and turns as it runs:
    #
    #   eye.move :ahead, by: 0.05 if held(:a)    # along its own arrows
    #   eye.turn :left, by: 2 if held(:left)     # degrees, :left :right :up :down
    #   eye.turn :right, by: spin                # or degrees the game works out
    #   eye.roll :right, by: 2 if held(:r)       # :left :right
    #   eye.at 0.0, 0.0, -4.0                    # put it somewhere
    #   eye.face right: [...], up: [...], ahead: [...]   # point it, three arrows of three numbers
    #
    # A turn keeps the arrows square and of length one, however many there are (IR::ViewerMotion).
    # `face` takes the arrows as given. `eye.spot` and `eye.right_arrow`, `eye.up_arrow`,
    # `eye.ahead_arrow` read them back, each three fractions.
    class Viewer
      PARTS = IR::PlaceDrawing::VIEWER_PARTS

      # How far from length one an arrow given to `facing:` may be, and how far from square to
      # the others.
      SLACK = 0.01

      BITS = Fraction::DEFAULT_BITS

      def initialize(builder, name)
        @builder = builder
        @name = name
        @motion = IR::ViewerMotion.new(->(part) { variable(part) })
      end

      attr_reader :name

      # The variable that holds +part+ of this viewer (one of PARTS, or a scratch part of
      # IR::ViewerMotion::SCRATCH).
      def variable(part) = Messages::MadeNames.make(:viewer_part, viewer: @name, part: part)

      # Every variable, in PARTS order.
      def variables = PARTS.map { |part| variable(part) }

      # The scratch variables a turn works in.
      def scratch_variables = IR::ViewerMotion::SCRATCH.map { |part| variable(part) }

      # Where the viewer is: [x, y, z], each a fraction.
      def spot = %i[x y z].map { |part| read(part) }

      # Which way it faces, each three fractions.
      def right_arrow = %i[right_x right_y right_z].map { |part| read(part) }
      def up_arrow = %i[up_x up_y up_z].map { |part| read(part) }
      def ahead_arrow = %i[ahead_x ahead_y ahead_z].map { |part| read(part) }

      # All three, as `facing:` takes them: a shape drawn standing where this viewer stands and
      # facing the way it faces (`draw_place :robot, seen_by: eye, at: bot.spot, facing: bot.facing`),
      # so a robot moves and turns with the viewer's own words.
      def facing = { right: right_arrow, up: up_arrow, ahead: ahead_arrow }

      # Put the viewer at +x+, +y+, +z+ (numbers, or values the game works out).
      def at(x, y, z)
        refuse_bad_numbers!("at", [x, y, z])
        %i[x y z].zip([x, y, z]).each { |part, number| store(part, number) }
        self
      end

      # Point the viewer: three arrows, each three numbers or values, taken as given.
      def face(right:, up:, ahead:)
        { right: right, up: up, ahead: ahead }.each do |arrow, numbers|
          refuse_bad_numbers!("face #{arrow}:", numbers)
          %i[x y z].zip(numbers).each { |axis, number| store(:"#{arrow}_#{axis}", number) }
        end
        self
      end

      # Move the viewer +by+ wholes (a number, or a value the game works out) along its own
      # arrows: :ahead, :back, :left, :right, :up or :down.
      def move(direction, by:)
        refuse_unknown_direction!("move", direction, IR::ViewerMotion::MOVES.keys)
        @motion.moved(direction, fraction_node(by)).each { |statement| @builder.record_statement(statement) }
        self
      end

      # Turn the viewer +by+ degrees :left, :right, :up or :down: a number, or a value the game
      # works out (whole or a fraction, below nought or past a whole turn; a fraction holds no
      # more than 32767 degrees either way).
      def turn(direction, by:)
        refuse_unknown_direction!("turn", direction, IR::ViewerMotion::TURNS.keys)
        record_turn(:turn, direction, by)
      end

      # Roll the viewer +by+ degrees round the way it faces, :left or :right, a number or a value
      # as #turn takes.
      def roll(direction, by:)
        refuse_unknown_direction!("roll", direction, IR::ViewerMotion::ROLL_SIGNS.keys)
        record_turn(:roll, direction, by)
      end

      private

      def read(part) = Value.new(@builder, IR::Build.var_ref(variable(part)), name: variable(part), fraction_bits: BITS)

      # A written number is turned by its own sine and cosine, settled now; a value the game works
      # out reads them from the table of sines as the game runs.
      def record_turn(kind, direction, degrees)
        statements = case degrees
                     when Numeric then @motion.turned_by_number(kind, direction, degrees)
                     when Value
                       whole = degrees.fraction_bits.nil?
                       turn_node = whole ? degrees.node : fraction_node(degrees)
                       scratch = IR::ViewerMotion::TURN_SCRATCH.map { |part| variable(part) }
                       sines = @builder.declare_viewer_sines_with_scratch(scratch)
                       @motion.turned_by_value(kind, direction, turn_node, sines, whole: whole)
                     else
                       raise ArgumentError, "eye.#{kind} was given by: #{degrees.inspect}. A turn is a number of " \
                                            "degrees. To fix this, give a number, like by: 2, or a value from `var`."
                     end
        statements.each { |statement| @builder.record_statement(statement) }
        self
      end

      # Set part +part+ of the viewer to +number+.
      def store(part, number)
        @builder.record_statement(IR::Build.set(variable(part), fraction_node(number)))
      end

      def fraction_node(number)
        return self.class.fraction_node(number, "A viewer") if number.is_a?(Numeric) || number.is_a?(Value)

        refuse_bad_numbers!("move by:", [number])
      end

      def refuse_unknown_direction!(verb, direction, directions)
        return if directions.include?(direction)

        raise ArgumentError, "eye.#{verb} was given #{direction.inspect}. The directions are " \
                             "#{directions.map(&:inspect).join(', ')}. To fix this, use one of them."
      end

      def refuse_bad_numbers!(what, numbers)
        return if numbers.is_a?(Array) && numbers.length == 3 && numbers.all? { |n| n.is_a?(Numeric) || n.is_a?(Value) }
        return if what == "move by:" && numbers.all? { |n| n.is_a?(Numeric) || n.is_a?(Value) }

        raise ArgumentError, "eye.#{what} was given #{numbers.inspect}. It takes numbers or values the game works " \
                             "out. To fix this, give three of them."
      end

      public

      # +number+ (a number, or a value the game works out) as a fraction with sixteen bits: a whole
      # value multiplied up, a fraction taken as it is. +who+ names what was given it, for the
      # friendly error a fraction of another size gets.
      def self.fraction_node(number, who)
        return IR::Build.int(Fraction.scale(number, BITS)) if number.is_a?(Numeric)
        return number.node if number.fraction_bits == BITS
        return IR::Build.binop(:*, number.node, 1 << BITS) if number.fraction_bits.nil?

        raise ArgumentError, "#{who} was given a number with #{number.fraction_bits} fraction bits. It takes a " \
                             "whole number or a fraction like 0.5. To fix this, give one of those."
      end

      # How far from length one, and from square to the others, three written arrows are, as one
      # of the reasons a facing is refused, or nil when they are a facing.
      def self.unfit_arrows_reason(arrows)
        return "an arrow is not of length one" unless arrows.all? { |arrow| (dot(arrow, arrow) - 1).abs <= SLACK }

        "two of its arrows are not square to each other" unless arrows.combination(2).all? { |one, other| dot(one, other).abs <= SLACK }
      end

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
        reason = unfit_arrows_reason(arrows)
        refuse_bad_facing!(name, reason) if reason
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
