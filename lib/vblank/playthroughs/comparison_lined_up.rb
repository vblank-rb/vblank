# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # TWO CARTRIDGES PLAYED STEP BY STEP, NOT FRAME BY FRAME: the first plays the tape a frame
      # at a time, as it always does, and the second is played on as far as each step the first
      # takes. A step is what each cartridge counts for itself: a pass of the game loop (Passes),
      # or a frame whose picture changed (StillFrames). The two are compared on the first frame
      # each shows each step, so a step that takes more frames on one than on the other is still
      # like with like.
      #
      # THE BUTTONS depend on what a step is. A game reads its buttons once a pass, so where the
      # steps are passes the second is held, on each frame it plays, the buttons the first held
      # on the frame that pass began on: the ones the first read. The first's buttons on its
      # other frames of that pass are given to neither (see Passes). A game that reads them on
      # every frame instead (in its frame interrupt, say; `reads_buttons_every_frame: true`) is
      # held, on every frame toward a pass, each button the first held on any of its frames since
      # the pass before: a press is caught by the same pass on both, though two quick presses
      # inside one pass become one. Where the steps are frames
      # whose picture changed, the game reads its buttons on the still frames too (a title screen
      # waits for START on one), so the second is held the first's buttons of every frame since
      # the step before, in order, one a frame: the last of them again if it takes more frames,
      # and the rest never if it takes fewer.
      #
      # A COUNT OF STEPS (Passes, StillFrames) answers `lined_up_on(first, second, part)` (one of
      # these; +part+ is the part of the screen looked at on every frame),
      # `refuse_unreadable_on!(cartridges)` (before a frame is played), `game_loop_count?(side)`
      # (whether that console has to keep the game loop's count) and `setting_name`.
      #
      # +first+ and +second+ are the two cartridges' counts as they play. Each answers
      # `read_after_frame!` (the step it shows after the frame just played, read once a frame),
      # `current_step` (that step again), `step_and_read!(keys)` (one frame played and read),
      # `counted_words` (what a step is, in words) and `refuse_stood_still!(wanted)` (the error
      # for a count that stopped short). +passes+ says whether a step is a pass, which a drift
      # names.
      class LinedUp
        # How many frames the second cartridge can play with its count standing still, short of
        # the step the first took, before the comparison stops: a minute.
        MOST_FRAMES_STILL = PassSteppedGame::MOST_FRAMES_STILL

        # How many frames the second cartridge has played.
        attr_reader :second_frames

        # +every_frame+ says the game reads its buttons on every frame and not once a pass (see
        # THE BUTTONS); it matters only where the steps are passes.
        def initialize(first, second, passes:, every_frame: false)
          @first = first
          @second = second
          @passes = passes
          @every_frame = every_frame
          @shown = nil
          @second_frames = 0
          @both_shown = 0
          @buttons_since_step = []
        end

        # Whether a step is a pass of the game loop.
        def passes? = @passes

        # AFTER A LEAD-IN, a pass can be under way on either cartridge, and the frame it began on
        # is behind it, so it cannot be compared on its first frame. Each count is read as the
        # lead-ins left it, and comparing starts at the first pass after both, each compared on
        # the first frame its cartridge shows it.
        def skip_passes_under_way!
          return unless @passes

          @shown = [@first.read_after_frame!, @second.read_after_frame!].max
        end

        # The step the first cartridge took on the frame it has just played, holding +keys+, or
        # nil when it shows one it has shown before.
        def read_step_begun_on_first!(keys)
          @buttons_since_step = [] if @passes && !@every_frame
          @buttons_since_step << keys
          step = @first.read_after_frame!
          return nil if @shown && step <= @shown

          @shown = step
        end

        # Play the second cartridge on, held the buttons the first was (see THE BUTTONS), until
        # its count shows +step+ or a later one, and answer whether it shows that very step,
        # which is then compared. It plays at least one frame the first time, since nothing is
        # shown before a frame is played.
        def play_second_to_step!(step)
          buttons = @buttons_since_step
          @buttons_since_step = []
          # A game that reads every frame is held, on each frame toward the pass, every button the
          # first held on any frame since its pass before, so a press on one of those frames is caught
          # by the same pass on both.
          buttons = [buttons.compact.reduce(0, :|)] if @every_frame && @passes
          still = 0
          until @second.current_step && @second.current_step >= step
            before = @second.current_step
            @second.step_and_read!(buttons.size > 1 ? buttons.shift : buttons.first)
            @second_frames += 1
            still = @second.current_step == before ? still + 1 : 0
            @second.refuse_stood_still!(step) if still >= MOST_FRAMES_STILL
          end
          (@second.current_step == step).tap { |shown| @both_shown += 1 if shown }
        end

        # The playing has ended. A comparison in which the second never showed a step the first
        # did compared nothing, and would pass whatever the two did: two counts that do not
        # count the same steps, most likely.
        def refuse_nothing_compared!
          return if @both_shown.positive? || @shown.nil?

          counted = @first.counted_words
          raise PassNotReached, "The second cartridge showed none of the #{counted} the first cartridge showed, so " \
                                "nothing was compared. The first cartridge's last was #{@shown}, and the second cartridge's " \
                                "count was #{@second.current_step}. Make the two counts count the same #{counted}, from " \
                                "the same number."
        end
      end
      private_constant :LinedUp
    end
  end
end
