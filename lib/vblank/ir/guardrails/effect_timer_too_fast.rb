# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about sound effects on a timer that ticks more often than a frame can hold:
        #
        # > The sound effects have `on_timer: true` and tick <number> times a second. The <console>
        # > shows <number> frames a second, so the timer ticks up to <number> times in one frame. A frame
        # > can play 8 ticks at most. To fix this, give the sound effects a slower `tempo:` or fewer
        # > `ticks_per_beat:`. Or remove `on_timer:`.
        #
        # A frame plays each of its ticks as a pass over the sound effects, so a timer this fast
        # would take much of the frame. The build stops and says the rate.
        #
        #--
        # The players keep the effects' timer as a count a frame adds a step to, and a frame has a
        # tick each time the count comes round (IR::Tunes.effect_clock_step). A step of
        # IR::Tunes::MOST_TICKS_A_FRAME whole counts or less keeps every frame to that many.
        #++
        class EffectTimerTooFast
          NAME = :effect_timer_too_fast
          PLAIN_NAME = "sound effects on a timer too fast for a frame"

          def detect(program)
            console = program.described_console
            step = Tunes.effect_clock_step(program, console)
            return [] unless step && Tunes.most_ticks_a_frame(step) > Tunes::MOST_TICKS_A_FRAME

            rate = Tunes.effect_timer_rate(program)
            song = program.walk.find { |node| node.kind == :song && node.timer_rate }
            [Finding.new(check: NAME, severity: :error, message: message(console, rate, step), node: song)]
          end

          private

          def message(console, rate, step)
            "The sound effects have `on_timer: true` and tick #{Tunes.timer_rate_words(rate)}. The " \
              "#{console.title} shows #{(1 / console.frame_seconds).to_f.round(2)} frames a second, so the timer " \
              "ticks up to #{Tunes.most_ticks_a_frame(step)} times in one frame. A frame can play " \
              "#{Tunes::MOST_TICKS_A_FRAME} ticks at most. To fix this, give the sound effects a slower `tempo:` or " \
              "fewer `ticks_per_beat:`. Or remove `on_timer:`."
          end
        end
      end
    end
  end
end
