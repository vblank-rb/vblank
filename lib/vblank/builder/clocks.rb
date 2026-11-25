# frozen_string_literal: true

module VBlank
  class Builder
    # The date and time
    #
    # `clock` gives the date and time, as the clock a cartridge carries keeps them. Its readings
    # are numbers like any variable's.
    #--
    # A concern of Builder, mixed in so `clock` stays a flat DSL verb.
    #++
    module Clocks
      # Gives the cartridge's clock, to read the date and time from.
      #
      # Its readings are `clock.hour`, `.minute`, `.second`, `.year`, `.month`, `.day` and
      # `.weekday`, and its tests are `clock.present?` and `clock.set?`. `clock.set_to` sets it.
      #
      # ```ruby
      # now = clock
      # draw_number now.minute, 60, 60, :white, digits: 2
      # ```
      def clock = DSL::Clock.new(self)

      # The hook behind `clock.set_to` (see DSL::Clock#set_to), which hands it the statement
      # that sets the clock. How far the time set is from the clock's own is kept in two saved
      # numbers (see IR::Clock::OFFSET_DAYS), saved like any `save_var` the moment they change,
      # so they are there at the next power-on.
      # Hook behind `set_to` on the clock, documented on `clock`.
      def record_clock_set(node)  # :nodoc:
        IR::Clock::OFFSETS.each { |name| save_var(name, 0) }
        record(node)
        IR::Clock::OFFSETS.each { |name| mirror_save(name) }
      end
    end
  end
end
