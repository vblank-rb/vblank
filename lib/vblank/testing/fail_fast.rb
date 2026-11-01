# frozen_string_literal: true

require "minitest"

module VBlank
  module Testing
    # FAIL_FAST=1: A RUN STOPS AT ITS FIRST FAILING TEST, for someone waiting on the answer. A whole
    # run takes a long while, and the first failure is usually what they came for.
    #
    # A reporter sees every result as it comes in, wherever the test was played, so this is one. It
    # prints the failure at once, since the report at the end of the run may not come. A
    # run in several processes stops handing out tests (Processes::Children), and the tests already
    # playing finish. A run in Ractors has nothing to hand out, so its process ends there.
    class FailFast < Minitest::AbstractReporter
      # +stop+ is what ends a run with no tests waiting to take back.
      def initialize(io, stop: -> { exit!(1) })
        super()
        @io = io
        @stop = stop
      end

      def record(result)
        return if result.passed? || result.skipped?

        @io.puts "", "Stopped at the first failure (#{Lowering::FAIL_FAST_SETTING}):", result.to_s
        @io.flush
        @stop.call
      end
    end
  end
end
