# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Testing
    # A TEST RUN WATCHED FOR THE TWO WAYS IT CAN STOP WITHOUT ENDING.
    #
    # When Ruby itself crashes it prints a report headed "[BUG]" and exits. In a run played in
    # Ractors it may not: the report's own writing can spin while the garbage collector waits for
    # the Ractor that crashed, and then nothing moves and nothing exits. A whole run holds the
    # machine-wide lock while that happens, so everything waiting behind it waits for ever. A run
    # is therefore played through a pipe, with its output passed on as it comes, and ended by
    # force a little after a crash report starts, or once it has printed nothing for a long time.
    #
    # What it printed from the crash on, and a sample of what the stuck process was doing where
    # the machine can take one, are kept in a folder, since the hang is the only evidence there
    # will be of a bug that shows once in fifty runs.
    class WatchedRun
      CRASH_HEADER = "[BUG]"

      # How long a crash report gets to finish, and how long a run may print nothing. A test that
      # plays quietly for ten minutes does not exist here: the suite prints a dot for each test.
      CRASH_GRACE_SECONDS = 30
      SILENCE_LIMIT_SECONDS = 600
      SAMPLE_SECONDS = 3

      POLL_SECONDS = 0.1

      # How a run ended. +stopped+ is why it was ended or crashed, :crash or :silence, or nil for
      # a run that ended by itself. +where+ is the first line of a test file in the crash report.
      Result = Data.define(:status, :stopped, :report_path, :where) do
        def stopped? = !stopped.nil?
        def ok? = !stopped? && status.success?

        def message
          return unless stopped?

          said = if stopped == :crash
                   "Ruby crashed while the run played #{where || 'a test'}."
                 else
                   "The run printed nothing for a long time, and it did not end."
                 end
          "#{said} VBlank ended the run. What the run printed last is in #{report_path}."
        end
      end

      def initialize(env, command, out: $stdout, keep_in: nil, crash_grace: CRASH_GRACE_SECONDS,
                     silence_limit: SILENCE_LIMIT_SECONDS, sample_seconds: SAMPLE_SECONDS)
        @env = env
        @command = command
        @out = out
        @keep_in = keep_in
        @crash_grace = crash_grace
        @silence_limit = silence_limit
        @sample_seconds = sample_seconds
        @printed = +""
        @crash_at = nil
      end

      def call
        reader, writer = IO.pipe
        pid = Process.spawn(@env, @command, out: writer, err: writer)
        writer.close
        @last_output = now
        why = pass_output_on(reader)
        _, ended = Process.wait2(pid, why ? Process::WNOHANG : 0)
        report = keep_report(pid, stuck: ended.nil?) if why || @crash_at
        ended ||= kill_stuck_run(pid)
        Result.new(status: ended, stopped: why || (:crash if @crash_at), report_path: report, where: crash_place)
      ensure
        reader&.close
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Passes the run's output on until it ends, and answers why it has to be ended, or nil.
      def pass_output_on(reader)
        loop do
          ready = reader.wait_readable(POLL_SECONDS)
          return nil if ready && !pass_chunk_on(reader)

          return :crash if @crash_at && now - @crash_at > @crash_grace
          return :silence if now - @last_output > @silence_limit
        end
      end

      # False once the run has closed its end, which is how it ends.
      def pass_chunk_on(reader)
        chunk = reader.read_nonblock(65_536, exception: false)
        return false if chunk.nil?
        return true if chunk == :wait_readable

        @out.write(chunk)
        @out.flush
        @last_output = now
        @printed = (@printed + chunk)[-MOST_KEPT_BYTES..] || (@printed + chunk)
        @crash_at ||= now if @printed.include?(CRASH_HEADER)
        true
      end

      MOST_KEPT_BYTES = 1_000_000

      def crash_place
        return unless @crash_at

        at = @printed.index(CRASH_HEADER)
        @printed[at..][TEST_LINE] || @printed[...at].scan(TEST_LINE).last
      end

      TEST_LINE = %r{\S*test_\w+\.rb:\d+}

      def kill_stuck_run(pid)
        Process.kill("KILL", pid)
        Process.wait2(pid).last
      end

      def keep_report(pid, stuck:)
        folder = @keep_in || Dir.mktmpdir("vblank-crash-")
        path = File.join(folder, "run-#{pid}.log")
        File.write(path, @printed)
        take_sample(pid, File.join(folder, "run-#{pid}.sample.txt")) if stuck
        path
      end

      # What every thread of the stuck process is doing, with the tool macOS has for it.
      def take_sample(pid, path)
        return unless @sample_seconds.positive? && RUBY_PLATFORM.include?("darwin")

        system("sample", pid.to_s, @sample_seconds.to_s, "-file", path, out: File::NULL, err: File::NULL)
      end
    end
  end
end
