# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # TWO CARTRIDGES PLAYED STEP BY STEP, NOT FRAME BY FRAME: the first plays the tape a frame
      # at a time, as it always does, and the second is played on as far as each step the first
      # takes. A step is what each cartridge counts for itself: a pass of the game loop (Passes),
      # or a frame whose picture changed (StillFrames). The two are compared on the first frame
      # each shows each step, or at each pass's end where that was asked for (Passes, AT THE END OF
      # EACH PASS), so a step that takes more frames on one than on the other is still like with
      # like.
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
      # `counted_words` (what a step is, in words) and `refuse_stood_still!(wanted, past:)` (the error
      # for a count that stopped short). +passes+ marks whether a step is a pass, which a drift
      # names.
      class LinedUp
        # How many frames the second cartridge can play with its count standing still, short of
        # the step the first took, before the comparison stops: a minute.
        MOST_FRAMES_STILL = PassStepper::MOST_FRAMES_STILL

        # How many frames the second cartridge has played.
        attr_reader :second_frames

        # +every_frame+ marks that the game reads its buttons on every frame and not once a pass (see
        # THE BUTTONS); it matters only where the steps are passes. +at_end+ marks that each step is
        # compared at its end and not on its first frame (Passes, AT THE END OF EACH PASS).
        def initialize(first, second, passes:, every_frame: false, at_end: false)
          @first = first
          @second = second
          @passes = passes
          @every_frame = every_frame
          @at_end = at_end
          @shown = nil
          @second_frames = 0
          @both_shown = 0
          @buttons_since_step = []
        end

        # Whether a step is a pass of the game loop.
        def passes? = @passes

        # Whether each step is compared at its end: the readings on its last frame and the picture
        # on the frame after it.
        def at_end? = @at_end

        # AFTER A LEAD-IN, COMPARING STARTS ON THE FIRST CARTRIDGE'S PASS, whichever cartridge is
        # ahead. A lead-in of the same frames on both can leave them passes apart, since one runs
        # late on frames the other does not, and starting at the later of the two would silently
        # leave out the passes in between on the one behind.
        #
        # The first's count is read as its lead-in left it. That pass is under way, and the frame it
        # began on is behind it, so it is not compared on its first frame: comparing starts at the
        # pass after it. Compared at their ends, that pass is compared too, since its end is still
        # ahead. The second is then played on to it as to any pass, from where its own lead-in left
        # it, or from power-on where it had none (+second_led_in+ false).
        #
        # A second whose lead-in left it past the first's pass has played the passes the comparison
        # starts on, and they cannot be played again: SecondAheadAfterLeadIns. Where the count wraps,
        # which of the two is ahead is the nearer way round (Passes::Count#count_in_lap_of!). A
        # second from power-on is read only once it has played a frame, and is refused the same way
        # if that first frame already shows a pass past the first's (see play_second_to_step!).
        # Its count is never put in the first's lap: it is behind, and plays on until its count
        # first shows the first's pass, modulo the wrap.
        def start_after_lead_ins!(second_led_in:)
          return unless @passes

          @start_pass = @first.read_after_frame!
          @start_pass_as_read = @first.count_as_read
          @second_from_power_on = !second_led_in
          if second_led_in
            @second.read_after_frame!
            second_pass = @second.count_in_lap_of!(@start_pass)
            refuse_second_ahead!(second_pass, "the lead-in of the second cartridge left its count") if second_pass > @start_pass
          end
          @shown = @at_end ? @start_pass - 1 : @start_pass
        end

        # The step to compare now, read off the first cartridge after the frame it has just played
        # holding +keys+, or nil for none: the step it began on this frame, or, compared at the end
        # of each step, the step this frame went past. A step compared already is never compared
        # again.
        def read_step_compared_on_first!(keys)
          @buttons_since_step = [] if @passes && !@every_frame
          @buttons_since_step << keys
          before = @first.current_step
          step = @first.read_after_frame!
          step = step_ended(before, step) if @at_end
          return nil if step.nil? || (@shown && step <= @shown)

          @shown = step
        end

        # The step a count that went from +before+ to +after+ on one frame went past, or nil where it
        # did not move on (or had shown nothing before).
        private def step_ended(before, after) = before && after > before ? before : nil

        # Play the second cartridge on, held the buttons the first was (see THE BUTTONS), until
        # its count shows +step+ or a later one, and answer whether it shows that very step,
        # which is then compared. It plays at least one frame the first time, since nothing is
        # shown before a frame is played. Compared at the end of each step, it plays on until its
        # count goes past +step+, and the step is compared when the frame before that showed it.
        # The block, if given, is called after each frame the second plays.
        def play_second_to_step!(step)
          buttons = @buttons_since_step
          @buttons_since_step = []
          # A game that reads every frame is held, on each frame toward the pass, every button the
          # first held on any frame since its pass before, so a press on one of those frames is caught
          # by the same pass on both.
          buttons = [buttons.compact.reduce(0, :|)] if @every_frame && @passes
          still = 0
          shown_before_last_frame = nil
          until second_reached?(step)
            before = @second.current_step
            @second.step_and_read!(buttons.size > 1 ? buttons.shift : buttons.first)
            @second_frames += 1
            yield if block_given?
            refuse_second_past_from_power_on!(step) if before.nil?
            still = @second.current_step == before ? still + 1 : 0
            @second.refuse_stood_still!(step, past: @at_end) if still >= MOST_FRAMES_STILL
            shown_before_last_frame = before
          end
          shown = @at_end ? shown_before_last_frame == step : @second.current_step == step
          shown.tap { @both_shown += 1 if shown }
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

        private

        # A second from power-on whose first frame shows a pass past +step+, the first step compared,
        # would go past the steps before it without showing them: a counter that starts high.
        def refuse_second_past_from_power_on!(step)
          return unless @second_from_power_on && @second.current_step > step

          refuse_second_ahead!(@second.current_step, "the first frame of the second cartridge from power-on shows its count")
        end

        # The second is on +second_pass+, past the pass the first's lead-in left it on, where
        # comparing starts. Both are counted in one lap. +where+ says how the second got there.
        def refuse_second_ahead!(second_pass, where)
          ahead = second_pass - @start_pass
          raise SecondAheadAfterLeadIns,
                "The lead-in of the first cartridge left its count of passes at pass #{@start_pass_as_read}, and " \
                "#{where} at pass #{@second.count_as_read}. The second cartridge is #{ahead} " \
                "#{ahead == 1 ? 'pass' : 'passes'} ahead. The comparison starts on the pass of the first cartridge, so the " \
                "passes before it on the second cartridge cannot be compared. Make the lead-in of the second cartridge " \
                "shorter, or give it no lead-in, like `lead_ins: [lead_in, nil]`. Then the second cartridge plays on to " \
                "the pass of the first cartridge. If the count of the second cartridge starts past that pass, count from " \
                "the same number on both."
        end

        # Whether the second cartridge's count has reached +step+: shows it, or a later one; or,
        # compared at the end of each step, shows a later one.
        def second_reached?(step)
          current = @second.current_step or return false

          @at_end ? current > step : current >= step
        end
      end
      private_constant :LinedUp
    end
  end
end
