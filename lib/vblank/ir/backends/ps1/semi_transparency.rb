# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE PLAYSTATION GRAPHICS CHIP MIXING A SEE-THROUGH TEXEL with the pixel under it, by its own rules,
        # written in Ruby so the checked run can mix a see-through layer on the interpreter's side the way the
        # chip mixes it in the emulator (Reference#mix_see_through_with). Like PolygonFill it is the answer key
        # for the chip, and no build uses it.
        #
        # The chip works in the five bits a channel video RAM holds, and never widens them. Each way
        # (Console::PS1Hardware::SEMI_TRANSPARENCY_MODES) is a sum of whole channels: half of each side with
        # the sum halved once, the two sides added, or a quarter of the texel (its two low bits dropped first)
        # added to the pixel under it, a sum stopping at 31. That is Beetle PSX's PlotPixel (mednafen/psx/
        # gpu_common.inc), which does the same to all three channels at once in one halfword. The
        # interpreter's own mix widens each channel to eight bits first (Framebuffer#mix_see_through), so a
        # pixel can be a step apart: 31 over 30 halved is 30 here and 31 there.
        module SemiTransparency
          CHANNEL_MAX = 31

          module_function

          # +color+ (the layer's 15-bit colour) over +under+, at +near+ sixteenths of the one and +far+ of the
          # other: only the shares the chip has a way for come here (Console::PS1Answers refuses the rest), and
          # the two that need no mix: the layer whole, which the chip draws as any other, and the layer not
          # seen, which the runtime does not draw.
          def mix(color, under, near, far)
            return color if [near, far] == Console::PS1Hardware::SOLID_SHARES
            return under if [near, far] == Console::PS1Hardware::HIDDEN_SHARES

            mode = Console::PS1Hardware::SEMI_TRANSPARENCY_MODES.fetch([near, far])
            [0, 5, 10].sum do |shift|
              front = (color >> shift) & CHANNEL_MAX
              back = (under >> shift) & CHANNEL_MAX
              channel_mix(front, back, mode) << shift
            end
          end

          # One channel, +front+ the texel's and +back+ the pixel under it, in way +mode+: the chip's own number
          # for it, which SEMI_TRANSPARENCY_MODES gives and the draw mode is told.
          def channel_mix(front, back, mode)
            case mode
            when 0 then (front + back) >> 1
            when 1 then [front + back, CHANNEL_MAX].min
            when 3 then [back + (front >> 2), CHANNEL_MAX].min
            else raise ArgumentError, "no see-through layer is mixed in the chip's way #{mode}"
            end
          end
        end
      end
    end
  end
end
