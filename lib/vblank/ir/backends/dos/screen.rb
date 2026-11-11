# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # THE SCREEN A PROGRAM IS BUILT FOR: the plain one (VGA mode 13h, 320 x 200) or a variant's
        # (`variants: { dos: :mode_x }`, Console::DOSKit). Everything in the build that depends on the screen
        # asks here and never the plain console, so a variant reaches all of it at once: how big the game's
        # picture is and where its edges are, how the card is set and sent the picture, and how long a frame
        # is, which the timer's rate and the clock count by.
        #
        # +mode+ is the video mode's name (:mode_13h, or the variant's Console::Variant#build[:video_mode]).
        # +cycles_a_frame+ and +cycles_a_second+ are the dots of the card's clock, as the console's
        # description counts a frame.
        Screen = Data.define(:width, :height, :mode, :cycles_a_frame, :cycles_a_second) do
          # The screen +program+ names: its variant's, or the plain one.
          def self.of(program)
            kit = Console.for(:dos)
            described = kit.described_as(program.variant)
            # No variant, or the name that asks for none (Console::Kit#variant gives nil for both).
            mode = kit.variant(program.variant)&.build&.fetch(:video_mode) || :mode_13h
            new(width: described.screen_width, height: described.screen_height, mode: mode,
                cycles_a_frame: described.cycles_a_frame, cycles_a_second: described.cycles_a_second)
          end

          def pixels = width * height
        end
      end
    end
  end
end
