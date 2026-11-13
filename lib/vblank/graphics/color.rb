# frozen_string_literal: true

module VBlank
  module Graphics
    # GBA color utilities.
    #
    # The GBA uses 15-bit color: 5 bits red, 5 bits green, 5 bits blue.
    # Format: 0bBBBBBGGGGGRRRRR (blue in high bits, red in low bits).
    # Each channel ranges from 0-31.
    module Color
      # Named color presets — common colors in GBA 15-bit format.
      PRESETS = {
        black:   0x0000,
        white:   0x7FFF,
        red:     0x001F,
        green:   0x03E0,
        blue:    0x7C00,
        yellow:  0x03FF,  # red + green
        cyan:    0x7FE0,  # green + blue
        magenta: 0x7C1F,  # red + blue
        orange:  0x02BF,  # r=31, g=10, b=0 (approx)
        gray:    0x2D6B,  # r=11, g=11, b=11
      }.freeze

      # The same table read the other way, for {name_for}. Built here rather than the first
      # time a message needs it, so a game building from a Ractor can read it — a worker may
      # not write to a module, and building a table on first use is a write.
      NAMES = Ractor.make_shareable(PRESETS.to_h { |name, resolved| [resolved, name.inspect] })

      module_function

      # Pack RGB channels (0-31 each) into a 15-bit GBA color.
      # Raises if any channel is out of the 0-31 range — this catches
      # the common mistake of passing 8-bit (0-255) values. Use
      # {from_hex} or {rgb8} if you're working with 8-bit color.
      #
      # @example
      #   Color.rgb(31, 0, 0)  # => bright red
      #   Color.rgb(0, 31, 0)  # => bright green
      def rgb(r, g, b)
        validate_channel!(r, "red")
        validate_channel!(g, "green")
        validate_channel!(b, "blue")
        r | (g << 5) | (b << 10)
      end

      # Pack 8-bit RGB channels (0-255 each) into a 15-bit GBA color.
      # Automatically downsamples to 5-bit per channel.
      #
      # @example
      #   Color.rgb8(255, 0, 0)  # => bright red (same as rgb(31, 0, 0))
      def rgb8(r, g, b)
        validate_channel8!(r, "red")
        validate_channel8!(g, "green")
        validate_channel8!(b, "blue")
        rgb(r >> 3, g >> 3, b >> 3)
      end

      # Convert a 24-bit hex color string to 15-bit GBA color.
      # Automatically downsamples from 8-bit (0-255) to 5-bit (0-31) per channel.
      #
      # @example
      #   Color.from_hex("#FF0000")  # => bright red
      #   Color.from_hex("00FF00")   # => bright green
      def from_hex(hex)
        hex = hex.delete_prefix("#")
        raise ArgumentError, "invalid hex color: #{hex}" unless hex.match?(/\A[0-9A-Fa-f]{6}\z/)

        r8 = hex[0, 2].to_i(16)
        g8 = hex[2, 2].to_i(16)
        b8 = hex[4, 2].to_i(16)

        rgb8(r8, g8, b8)
      end

      def validate_channel!(value, name)
        return if (0..31).cover?(value)

        hint = value > 31 ? " (did you mean rgb8 for 8-bit values?)" : ""
        raise ArgumentError, "#{name} channel #{value} out of range (0-31)#{hint}"
      end

      def validate_channel8!(value, name)
        return if (0..255).cover?(value)

        raise ArgumentError, "#{name} channel #{value} out of range (0-255)"
      end

      # Resolve a color from multiple input types.
      #
      # @param value [Symbol, String, Integer] color value
      # @return [Integer] 15-bit GBA color
      #
      # @example
      #   Color.resolve(:red)        # => named preset
      #   Color.resolve("#FF8800")   # => hex string
      #   Color.resolve(0x001F)      # => raw 15-bit value (passed through)
      def resolve(value)
        case value
        when Integer
          value & 0x7FFF
        when Symbol
          PRESETS.fetch(value) { raise ArgumentError, "unknown color: #{value}. Known: #{PRESETS.keys.join(', ')}" }
        when String
          from_hex(value)
        else
          raise ArgumentError, "expected Integer, Symbol, or hex String, got #{value.class}"
        end
      end

      # +color+ as a console that keeps only the top +bits+ of each channel shows it: those bits, each
      # channel widened back to five by repeating them, which is how such a picture is read back (the
      # Genesis keeps three).
      #
      # @example
      #   Color.kept(Color.resolve(:gray), bits: 3)  # => 0x2529, the gray a Genesis shows
      def kept(color, bits:)
        return color if bits >= 5

        lost = 5 - bits
        kept_mask = (1 << bits) - 1
        [0, 5, 10].sum do |at|
          level = (color >> (at + lost)) & kept_mask
          ((level << lost) | (level >> (bits - lost))) << at
        end
      end

      # How many steps a channel of a color has from one end to the other.
      CHANNEL_STEPS = 31

      # +color+ with each of its three channels moved +steps+ toward +far+'s, and no further: one
      # step of a walk from one color to another (Builder#color_walk). A build works a walk's
      # steps out with this, and so does whatever plays a game that learns the color only as it
      # starts (IR::StartFile::WalkedColor), which the runtimes for a computer write again as
      # rg_start_file_walk_colors.
      def walked_toward(color, far, steps)
        [0, 5, 10].sum do |shift|
          own = (color >> shift) & CHANNEL_STEPS
          limit = (far >> shift) & CHANNEL_STEPS
          (own < limit ? [own + steps, limit].min : [own - steps, limit].max) << shift
        end
      end

      # +color+ as a walk from +far+ that WAITS FOR A FALLING COUNT shows it after +steps+ steps:
      # the rule of a fade routine of the console's own games, where every channel of any height
      # arrives on the last step together (Builder#color_walk's count:). Each channel starts at
      # +far+'s. On step n the count is +count+ less +step+ n times, and never below 0. A channel
      # that has passed its height (+color+'s) moves +step+ back toward it and no further; one at
      # its height stays; one whose distance still to go is less than the count waits; any other
      # moves +step+ toward its height, held to the channel's range, and so can pass it, coming back
      # on the next step. A walk of +count+ / +step+ + 1 steps brings every channel home when
      # +step+ divides +count+.
      #
      # It is the one statement of the rule: the build works a walk's steps out with it, and so
      # does the interpreter for a list it reads from the data pack as it starts
      # (IR::StartFile::CountedWalkColor), which the runtimes for a computer write again as
      # rg_start_file_count_walk_colors.
      def counted_walk(color, far, step:, count:, steps:)
        [0, 5, 10].sum do |shift|
          height = (color >> shift) & CHANNEL_STEPS
          level = (far >> shift) & CHANNEL_STEPS
          # 1 for a walk up, -1 for one down. A channel past its height is on the far side of it
          # from where it started, so what it has to go is below 0.
          toward = height > level ? 1 : -1
          (1..steps).each do |number|
            now = [count - (step * number), 0].max
            to_go = (height - level) * toward
            if to_go.negative?
              level -= toward * step
              level = height if ((height - level) * toward).positive?
            elsif to_go.positive? && to_go >= now
              level = (level + (toward * step)).clamp(0, CHANNEL_STEPS)
            end
          end
          level << shift
        end
      end

      # A color as a person would name it — :magenta where there is a name for it, and
      # the raw value where there is not. For messages: an author reading about a color
      # in their own art wants the word they typed, not a number they never saw.
      def name_for(value)
        NAMES.fetch(value) { format("#%04X", value) }
      end
    end
  end
end
