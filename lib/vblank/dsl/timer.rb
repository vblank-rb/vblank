# frozen_string_literal: true

module VBlank
  module DSL
    # A hardware timer
    #
    # A counter that runs at a rate you choose, on its own and apart from the frames.
    # Builder#timer hands one back: `timer :beat, per_second: 4` ticks four times a second.
    #
    # ```ruby
    # beat = timer :beat, per_second: 4
    # if beat.ticks > last_beat   # ticks climbs four times a second
    #   last_beat = beat.ticks
    # end
    # beat.stop
    # ```
    #
    # Timer#ticks is how many times it has ticked since it started, a Value that reads and
    # compares like any other. The framework looks after the hardware behind it.
    #--
    # The rate becomes a prescaler and reload, and reading the count is handled for the game.
    # Later, a timer is meant to clock sampled audio too.
    #++
    class Timer
      # Built by Builder#timer, which starts the timer and reserves its hardware.
      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # The timer's name, as the game gave it to Builder#timer.
      attr_reader :name

      # How many times the timer has ticked since it started, as a Value.
      #
      # The count goes back to 0 after 65535. Reading it keeps a little extra hardware busy to
      # hold the count, so a timer you never read costs less.
      #
      # ```ruby
      # draw_number beat.ticks, 8, 8, :white
      # ```
      def ticks
        Value.new(@builder, IR::Build.timer_ticks(@name))
      end

      # Runs the block every time the timer ticks, at the timer's own rate.
      #
      # The timer itself runs the block, so it keeps the timer's rate exactly, apart from the
      # game loop, where Builder#every and Builder#after can go no faster than the frames. It
      # returns the timer, so calls chain.
      #
      # ```ruby
      # timer(:beat, per_second: 100).on_tick { clicks += 1 }
      # ```
      #
      # This is a building block for friendlier features, such as a metronome or music timing,
      # so a game generally reaches for those first. The block runs between the game loop's
      # steps, so if it and the loop both change one variable they can get in each other's way:
      # give the block its own variables.
      #
      # The block belongs to the timer from power-on, wherever the line is written, the same as
      # Builder#once_a_frame: one inside a routine nothing calls still runs once the timer does,
      # and a second block for the same timer replaces the first.
      def on_tick(&block)
        @builder.record_container(IR::Build.on_timer(@name), &block)
        self
      end

      # Stops the timer, which keeps the tick count it has reached.
      #
      # It returns the timer, so calls chain.
      #
      # ```ruby
      # beat.stop if pressed(:start)
      # ```
      def stop
        @builder.record_statement(IR::Build.timer_stop(@name))
        self
      end
    end
  end
end
