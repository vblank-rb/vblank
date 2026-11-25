# frozen_string_literal: true

module VBlank
  class Builder
    # Hardware timers
    #
    # `timer` starts a counter that runs at a rate you choose, on its own and apart from the
    # frames. The handle it gives back reads the ticks and stops it.
    #--
    # A concern of Builder, mixed in so `timer` stays a flat DSL verb.
    #++
    module Timers
      # Starts a counter that ticks a number of times a second, and returns a handle to read its
      # ticks and stop it.
      #
      # Calling `timer` again with the same name restarts it, and its tick count goes back to
      # zero. For timing that follows the frames, use `every` or `after` instead. A timer is for
      # precise timing that keeps counting on its own.
      #
      # ```ruby
      # beat = timer :beat, per_second: 2   # ticks twice a second
      # ```
      #
      # * `name` - the timer's name, as a symbol.
      # * `per_second:` - how many times a second it ticks: a positive whole number.
      def timer(name, per_second:)
        raise ArgumentError, "A timer name must be a Symbol. Got #{name.inspect}. Use a name like :beat." unless name.is_a?(Symbol)
        unless DSL::Whole.positive?(per_second)
          raise ArgumentError,
                "timer :#{name} needs per_second to be a positive whole number of ticks a second. " \
                "Got #{Messages::PlainWords.words_for_given(per_second)}. " \
                "For slower or fractional timing, use `every` or `after` by frames or seconds."
        end

        # The IR speaks in Hz (overflows per second) — the same number, named for what it
        # is one layer down.
        record(IR::Build.timer_start(name, per_second))
        DSL::Timer.new(self, name)
      end
    end
  end
end
