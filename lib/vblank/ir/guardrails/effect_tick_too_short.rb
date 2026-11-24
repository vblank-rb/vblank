# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about sound effects on a timer that ticks as fast as the console shows frames, or faster:
        #
        # > The sound effects have `on_timer: true` and tick <number> times a second. The <console>
        # > shows <number> frames a second. On the timer, a tick must be longer than one frame. To fix
        # > this, give the sound effects a slower `tempo:` or fewer `ticks_per_beat:`. Or remove
        # > `on_timer:`.
        #
        # A sound effect on the timer plays at most one tick on a frame, so a timer this fast could
        # lose ticks. The build stops and says the rate.
        #
        #--
        # The players keep the effects' timer as a count a frame adds a step to, and a frame has a
        # tick when the count comes round (IR::Tunes.effect_clock_step). That gives a frame one tick
        # or none, which is all a tick longer than a frame needs and all the players do with it. A
        # tick of exactly a frame makes the step the whole count, which does not fit in its 16 bits,
        # and a faster timer would want a frame to play several ticks.
        #++
        class EffectTickTooShort
          NAME = :effect_tick_too_short
          PLAIN_NAME = "sound effects on a timer as fast as the frames or faster"

          def detect(program)
            console = program.described_console
            step = Tunes.effect_clock_step(program, console)
            return [] unless step && step >= Tunes::CLOCK_MODULUS

            rate = Tunes.effect_timer_rate(program)
            song = program.walk.find { |node| node.kind == :song && node.timer_rate }
            [Finding.new(check: NAME, severity: :error, message: message(console, rate), node: song)]
          end

          private

          def message(console, rate)
            "The sound effects have `on_timer: true` and tick #{Tunes.timer_rate_words(rate)}. The " \
              "#{console.title} shows #{(1 / console.frame_seconds).to_f.round(2)} frames a second. On the timer, a " \
              "tick must be longer than one frame. To fix this, give the sound effects a slower `tempo:` or fewer " \
              "`ticks_per_beat:`. Or remove `on_timer:`."
          end
        end
      end
    end
  end
end
