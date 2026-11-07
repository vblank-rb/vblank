# frozen_string_literal: true

module VBlank
  module IR
    # WHERE A NAMED SPRITE'S STATE IS KEPT, so anything reading a running game asks for the sprite
    # by the game's name for it rather than by the hidden variables the build made for it
    # (__obj1_x, __spr2_on). The build writes one for each sprite a game declared on the program
    # (Program#sprite_readings), and every reader answers #state_from with its own stored numbers.
    #
    # +x+, +y+ and +shown+ name the variables holding its place and whether it is shown. +poses+
    # is its pictures in the order its pose number counts them; the number is +facing+ (or a
    # plain sprite's 0), times +frames_per_facing+, plus +frame+ for one that animates within a
    # facing; a sprite playing named clips counts from +clip_start+ instead. +angle+ and +scale+
    # name the variables a sprite told to turn or to change size keeps those in, and are nil for
    # one never told to, which stands upright at its drawn size.
    SpriteReading = Data.define(:name, :x, :y, :shown, :poses, :facing, :frame, :frames_per_facing, :clip_start,
                                :angle, :scale) do
      def initialize(angle: nil, scale: nil, **parts)
        super
      end

      # The sprite as it stands, read through +stored+ (a variable's name to its stored number).
      def state_from(stored)
        SpriteState.new(name: name, x: stored.call(x), y: stored.call(y), shown: stored.call(shown) != 0,
                        pose: poses[pose_number(stored)], angle: angle ? stored.call(angle) : 0,
                        scale: scale ? Rational(stored.call(scale), Build::SCALE_ONE) : 1)
      end

      private

      def pose_number(stored)
        return stored.call(clip_start) + stored.call(frame) if clip_start
        return 0 unless facing
        return stored.call(facing) unless frame

        (stored.call(facing) * frames_per_facing) + stored.call(frame)
      end
    end

    # A name several sprites were given: none of them can be read by it, and asking says how to
    # give each a name of its own.
    SharedName = Data.define(:name, :count) do
      def message
        "#{count} sprites are called :#{name}, so a test cannot tell which one you mean. To read one, give each " \
          "sprite a name of its own and say which image it shows: `sprite :#{name}1, image: :#{name}, at: [x, y]`."
      end
    end

    # A named sprite read back: where it is, whether it is shown, the picture it is showing, the
    # angle it is turned to in degrees, and its size, 1 for as drawn (a Rational, exactly as kept:
    # 3/2 for half as big again).
    SpriteState = Data.define(:name, :x, :y, :shown, :pose, :angle, :scale) do
      def shown? = shown
    end
  end
end
