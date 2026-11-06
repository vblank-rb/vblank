# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A FADE OR A TINT THAT WALKS THE COLOURS (IR::Fading#palette_walk?), as a console with no
      # blend does every one: every colour the game shows moved part of the way toward black, white
      # or a colour of the game's, and the moved colours sent to the console's colour memory. What that walk is, and when it is done, is the
      # same on every console that does it, so it is set out here once and each lowering hands its
      # runtime what this works out. The runtime then does only what its own hardware asks: how it
      # multiplies a channel, how many bits a channel keeps, where it keeps the colours and how it
      # sends them in the blank.
      #
      # THE RULES, each the interpreter's (Reference#exec_fade, #exec_tint, Framebuffer#walked_toward
      # and #mixed):
      #
      # - A walk is three things: toward what (black, white, or a colour, as TOWARD_BLACK, TOWARD_WHITE
      #   and TOWARD_COLOR), the colour (nought for black and white), and how far, in FadeSteps'
      #   256ths of the way. The steps are held to 0..FadeSteps::WALK, so a fade past 100 is a fade
      #   all the way and one below nought is none. Walk#steps holds them before the call, as the
      #   game runs where the amount is worked out then, and costs nothing for an amount written in
      #   the game. At power-on the state is toward black by no steps.
      # - No steps is the colours as they are, whatever they were walked toward, and a runtime
      #   asks the steps, not where they go, whether there is any walk to do.
      # - Asked for again the same as the walk in force, it does nothing: a game writes `tint :red, hurt`
      #   every pass, and almost every pass nothing moved. Only a change works the colours out.
      # - The colours walked are the ones each picture is drawn in NOW: the declared set of a list,
      #   or the set the game told it to hold (Reference#colors_held_by), so a list that changes
      #   and a walk in force meet on the same pass, whichever was given first.
      # - The work is done as the pass ends and sent in the blank, so the moved colours show on the
      #   picture of the pass that asked for them, with the sprites and the scroll, and a pass that asks for
      #   several walks (a fade catching up on frames a slow pass took) works the colours out once.
      #
      # A walk placed under a layer or held to part of the screen needs a blend, and a console with
      # none refuses it in its answers' words (Console::Questions, :fade) before anything is made;
      # Fading never asks a console that cannot blend to walk one.
      #
      # TWO CONSOLES DO PART OF THIS THEIR OWN WAY, and neither changes the answer, which the checked
      # runs hold to the interpreter:
      #
      # - The Advance blends, so most of its fades are the display's, and the walk it does
      #   (GBA::PaletteTint) counts a game's whole percentages in thirty-seconds, so that the steps
      #   and the colour fit one state word: one compare tells the walk is unchanged, and one AND
      #   reads the steps back, where 256ths take a shift each way. It holds the steps to their
      #   range in the ARM that packs that word, with no call to hand them to.
      # - The Super Nintendo holds the steps in rt_tint, once, rather than before each call
      #   (Walk#unheld_steps): its 65816 holds a 32-bit number between two ends in several dozen
      #   bytes of code, written again at every fade the game works out, where rt_tint holds it in
      #   a dozen instructions written once.
      module PaletteWalk
        TOWARD_BLACK = 0
        TOWARD_WHITE = 1
        TOWARD_COLOR = 2

        # What a runtime is handed for a walk: +toward+ (one of the TOWARD_ numbers) and +color+ (a
        # 15-bit colour, nought toward black or white), numbers known while building, and
        # +unheld_steps+, the value the game works out the steps from, which may be past either end.
        Walk = Data.define(:toward, :color, :unheld_steps) do
          # The steps, held to 0..FadeSteps::WALK.
          def steps = Build.clamped(unheld_steps, Build.int(0), Build.int(FadeSteps::WALK))
        end

        module_function

        # The Walk a `fade` or `tint` node asks for.
        def walk_for(node)
          steps = FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: true)
          if node.kind == :tint
            return Walk.new(toward: TOWARD_COLOR, color: Graphics::Color.resolve(node.color), unheld_steps: steps)
          end

          Walk.new(toward: node.toward == :white ? TOWARD_WHITE : TOWARD_BLACK, color: 0, unheld_steps: steps)
        end
      end
    end
  end
end
