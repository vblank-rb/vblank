# frozen_string_literal: true

module VBlank
  module IR
    # HOW A VIEWER MOVES AND TURNS, as statements every target runs (see DSL::Viewer). A viewer is
    # a spot and three arrows of length one, square to each other: right, up and ahead. Every
    # number is a fraction with sixteen bits, and every product goes through Int32.mul_fix.
    #
    # MOVING is the spot moved along one of its own arrows: forward along ahead, sideways along
    # right, up along up.
    #
    # TURNING swings two of the arrows round the third, by an angle settled while the game is
    # built, so its cosine and sine are numbers written into the program and no table is needed.
    # Turning left swings ahead towards where right pointed away from; tipping up swings ahead
    # towards up; rolling left swings up towards where right pointed away from.
    #
    # SQUARING UP. Each turn rounds its products down, so after many turns the arrows would drift
    # a little longer or shorter and a little out of square, and the place would be drawn
    # stretched or skewed. So every turn ends by making them square and of length one again:
    # ahead is made length one, up has whatever part of it lies along ahead taken away and is made
    # length one, and right is made from the two. Making an arrow length one needs no square root:
    # an arrow nearly length one, multiplied by (3 - its length squared) / 2, comes out nearer
    # length one by far, and a turn moves it only a little each time (one step of Newton's method
    # for one over a square root).
    class ViewerMotion
      ONE = 1 << 16
      AXES = %i[x y z].freeze

      # The arrow a direction moves along, and which way.
      MOVES = Ractor.make_shareable({ ahead: [:ahead, 1], back: [:ahead, -1], right: [:right, 1], left: [:right, -1],
                                      up: [:up, 1], down: [:up, -1] })

      # Which arrow turns towards which, and which way, for each direction of `turn` and `roll`
      # (see #turned): the first is swung away from the second by the angle.
      TURNS = Ractor.make_shareable({ left: %i[ahead right], right: %i[ahead right], up: %i[up ahead], down: %i[up ahead] })
      TURN_SIGNS = { left: 1, right: -1, up: 1, down: -1 }.freeze
      ROLL_SIGNS = { left: 1, right: -1 }.freeze

      # +variable+ answers the variable of the viewer's part (one of IR::PlaceDrawing::VIEWER_PARTS
      # or a scratch part, :t0 to :t2 and :length), as DSL::Viewer#variable does.
      def initialize(variable)
        @variable = variable
      end

      # The scratch parts the statements use beside the viewer's own.
      SCRATCH = %i[t0 t1 t2 length along].freeze

      # The spot moved +distance+ (a value, a fraction with sixteen bits) along the arrow
      # +direction+ names.
      def moved(direction, distance)
        arrow, sign = MOVES.fetch(direction)
        step = sign.negative? ? Build.neg(distance) : distance
        AXES.map { |axis| Build.add(part(axis), Build.mul_fix(step, var(:"#{arrow}_#{axis}"), 16)) }
      end

      # The arrows turned (+:turn+ or +:roll+) +direction+ by +degrees+, then squared up.
      def turned(kind, direction, degrees)
        swung, toward = kind == :roll ? %i[up right] : TURNS.fetch(direction)
        sign = (kind == :roll ? ROLL_SIGNS : TURN_SIGNS).fetch(direction)
        swing(swung, toward, sign * degrees) + squared_up
      end

      # Arrows +a+ and +b+ swung by +degrees+: a' = a cos - b sin, b' = b cos + a sin. The new a is
      # kept aside until the new b is worked out from the old a.
      def swing(a, b, degrees)
        cosine = (Math.cos(degrees * Math::PI / 180) * ONE).round
        sine = (Math.sin(degrees * Math::PI / 180) * ONE).round
        across = lambda do |one, other, sign|
          AXES.map do |axis|
            Build.binop(sign, Build.mul_fix(var(:"#{one}_#{axis}"), Build.int(cosine), 16),
                        Build.mul_fix(var(:"#{other}_#{axis}"), Build.int(sine), 16))
          end
        end
        across.call(a, b, :-).each_with_index.map { |value, i| Build.set(part(:"t#{i}"), value) } +
          across.call(b, a, :+).each_with_index.map { |value, i| Build.set(part(:"#{b}_#{AXES[i]}"), value) } +
          AXES.each_with_index.map { |axis, i| Build.copy(part(:"#{a}_#{axis}"), part(:"t#{i}")) }
      end

      # Ahead made length one, up made square to it and length one, and right made from the two.
      def squared_up
        [*length_one(:ahead),
         Build.set(part(:along), dot(:up, :ahead)),
         *AXES.map { |axis| Build.sub(part(:"up_#{axis}"), Build.mul_fix(var(:along), var(:"ahead_#{axis}"), 16)) },
         *length_one(:up),
         *cross_into_right]
      end

      private

      def part(name) = @variable.call(name)

      def var(name) = Build.var_ref(part(name))

      def dot(one, other)
        AXES.map { |axis| Build.mul_fix(var(:"#{one}_#{axis}"), var(:"#{other}_#{axis}"), 16) }
            .reduce { |sum, product| Build.binop(:+, sum, product) }
      end

      # The arrow multiplied by (3 - its length squared) / 2.
      def length_one(arrow)
        factor = Build.shift_right(Build.binop(:-, 3 * ONE, dot(arrow, arrow)), 1)
        [Build.set(part(:length), factor),
         *AXES.map { |axis| Build.set(part(:"#{arrow}_#{axis}"), Build.mul_fix(var(:"#{arrow}_#{axis}"), var(:length), 16)) }]
      end

      # right = up × ahead.
      def cross_into_right
        product = lambda do |first, second|
          Build.binop(:-, Build.mul_fix(var(:"up_#{first}"), var(:"ahead_#{second}"), 16),
                      Build.mul_fix(var(:"up_#{second}"), var(:"ahead_#{first}"), 16))
        end
        [Build.set(part(:right_x), product.call(:y, :z)), Build.set(part(:right_y), product.call(:z, :x)),
         Build.set(part(:right_z), product.call(:x, :y))]
      end
    end
  end
end
