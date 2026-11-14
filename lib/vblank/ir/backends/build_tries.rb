# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A CARTRIDGE BUILD AS A SERIES OF TRIES, each a whole lowering of the game with one set of
      # settings, until one fits. A console that sees its cartridge a bank at a time, with a few
      # hundred tiles and a few lists of colours at once, cannot tell from the program alone how a
      # game must be kept to fit: it tries the simple way first, and a try that does not fit stops
      # at the first thing that does not (too many tiles, too many lists of colours, a part of the
      # cartridge too full), which decides what the next try changes. A game that fits at the first
      # try builds the bytes it always did; a big one takes several tries.
      #
      # THE DECISION, shared by every such console so it is made once (the Color's, the Super
      # Nintendo's and the Genesis's builds all run on this):
      #
      # - THE ORDER OF THE STEPS is each console's: its step is handed the error that stopped a try
      #   and the try, and gives the settings of the next try, or nil where nothing it can change
      #   would help, and the error stands. The settings are one value (a Data), so a try is known
      #   by its settings alone.
      # - WHAT A TRY FOUND IS KEPT for every later try. The next settings are the last ones with one
      #   thing more, never a fresh start, because what a try finds (these sprites need more tiles
      #   than the console holds) is a fact about the game and not about that try. A step that must
      #   start part of its settings over says so in the settings it gives.
      # - A TRY THAT IS SURE TO FAIL STOPS as soon as it is: each console's lowering raises the
      #   moment a count passes what the console holds, rather than at the end of the try (the
      #   console's own checks; see each lowering's Art). And a try that has found one thing that
      #   does not fit, of a kind several parts of the game can each have, finds them all before it
      #   stops (the Super Nintendo's crowded scenes), so one try does what one try per part did.
      # - A STEP THE LAST TRY'S MEASUREMENTS RULE OUT IS SKIPPED, untried (#first_step_not_ruled_out):
      #   a part of the cartridge too full by more than a step can move, tiles past the room a step
      #   leaves. The measurements are each console's.
      # - A STEP MAY BE AN ATTEMPT (Attempt): one way of fitting that is worth trying before the
      #   others but may not work, and if the tries after it fail, the build goes back to where it
      #   was and carries on there. And a try that fits may be followed by one that would be better
      #   (more of the game the fast way), kept only if it fits too (+better+ in #run).
      #
      # What the build works out from the program alone, and not from how a try is built, is
      # BuildCache's, made once for all the tries. Each try is timed and said at debug level
      # (VBLANK_LOG=debug), with the error that stopped it and the settings it changed.
      class BuildTries
        # One try of the build: its number from 1, the settings it was made with, and what it made
        # that a step reads to decide the next settings (+made+, a console's lowering, set by the
        # try as it goes). Once it ends: how long it took, and the error that stopped it, nil for
        # the try that fit.
        class Try
          attr_reader :number, :settings, :seconds, :stopped_by
          attr_accessor :made

          def initialize(number, settings)
            @number = number
            @settings = settings
          end

          def finish(seconds, stopped_by)
            @seconds = seconds
            @stopped_by = stopped_by
          end
        end

        # A next try that can be given up (#run): +settings+ to try, and what the build does if that
        # try, or any try after it, stops with an error that no step answers and that is one of
        # +given_up_on+ and none of +except+: it tries +otherwise+ instead, or with nil raises the
        # error the attempt was made for. An error it does not give up on is raised as it is.
        Attempt = Data.define(:settings, :otherwise, :given_up_on, :except) do
          def initialize(settings:, otherwise: nil, given_up_on: [StandardError], except: []) = super

          def gives_up_on?(error) = given_up_on.any? { |kind| error.is_a?(kind) } && except.none? { |kind| error.is_a?(kind) }
        end

        # An attempt the build can go back from: the attempt, the error it was made for, and the
        # result of a try that fit before it, kept in case a better one does not (#run's +better+).
        ChoicePoint = Data.define(:attempt, :error, :kept)

        # Where the build goes after a choice point gives up: +settings+ to try, or a +result+ to
        # return.
        Resumption = Data.define(:settings, :result)

        # The first of the steps from +first+ on (each the one after the last, by +following+, nil
        # past the last) that the block does not rule out, nil for none. The block is given a step
        # and says whether the last try's measurements show that step cannot fit.
        def self.first_step_not_ruled_out(first, following:)
          step = first
          step = following.call(step) while step && yield(step)
          step
        end

        # Every try the last #run made, in order (Try).
        attr_reader :tries

        # +console+ is how the log names the console (its title); +first+ the settings of the first
        # try.
        def initialize(console, first)
          @console = console
          @first = first
          @tries = []
        end

        # How many tries the last #run made: one for a game that fits as it first tries.
        def count = @tries.length

        # THE BUILD: the block is one try, given the Try and giving back what fit (a cartridge). A try
        # that raises is handed to +next_settings+ (given the error and the Try), which gives the next
        # settings, an Attempt, or nil. Nil gives the build back to the last open attempt that gives up
        # on the error, or raises it where none does. +better+, where given, is asked after a try fits
        # (given the Try and its result): an Attempt to make one more try, the fitting result kept if
        # it fails, or nil to finish.
        def run(next_settings:, better: nil)
          @tries = []
          choices = []
          settings = @first
          loop do
            try = Try.new(@tries.length + 1, settings)
            @tries << try
            started = now
            begin
              result = yield(try)
            rescue StandardError => e
              try.finish(now - started, e)
              log(try)
              resumed = resume_after(e, try, choices, next_settings)
              return resumed.result unless resumed.settings

              settings = resumed.settings
              next
            end
            try.finish(now - started, nil)
            log(try)
            improved = better&.call(try, result)
            return result unless improved

            choices << ChoicePoint.new(attempt: improved, error: nil, kept: result)
            settings = improved.settings
          end
        end

        private

        # Where the build goes after +error+ stopped +try+: the next step's settings, or, where no step
        # helps, the open attempt that gives up on it.
        def resume_after(error, try, choices, next_settings)
          step = next_settings.call(error, try)
          if step.is_a?(Attempt)
            choices << ChoicePoint.new(attempt: step, error: error, kept: nil)
            return Resumption.new(settings: step.settings, result: nil)
          end
          return Resumption.new(settings: step, result: nil) if step

          while (choice = choices.pop)
            next unless choice.attempt.gives_up_on?(error)
            return Resumption.new(settings: nil, result: choice.kept) if choice.kept
            raise choice.error unless choice.attempt.otherwise

            return Resumption.new(settings: choice.attempt.otherwise, result: nil)
          end
          raise error
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Says +try+ at debug level: its number, its time, what stopped it, and the settings it had
        # that the first try did not.
        def log(try)
          VBlank.logger.debug("build") do
            stopped = try.stopped_by ? "stopped by #{try.stopped_by.class.name.split('::').last}" : "fits"
            changed = changed_settings(try.settings)
            "#{@console} try #{try.number}: #{format('%.2f', try.seconds)} s, #{stopped}#{"; #{changed}" unless changed.empty?}"
          end
        end

        # The fields of +settings+ that differ from +first+'s, a field that is settings of its own
        # (a Data) by its own fields that differ.
        def changed_settings(settings, first = @first)
          return settings.inspect unless settings.is_a?(Data) && first.is_a?(Data)

          was = first.to_h
          settings.to_h.reject { |key, value| was[key] == value }.map do |key, value|
            value.is_a?(Data) && was[key].is_a?(Data) ? changed_settings(value, was[key]) : "#{key}: #{value.inspect}"
          end.join(", ")
        end
      end
    end
  end
end
