# frozen_string_literal: true

require "json"

module VBlank
  module Live
    # A WINDOW WAITING FOR ITS GAME WHILE ANOTHER PROCESS BUILDS IT. vblank run opens the window at
    # once and a helper process (BuildHelper) builds the game and writes it out as one Ruby file,
    # saying as it goes what it is doing. This reads what the helper says and has the device show
    # it, a frame at a time, until the helper says where the game is written, or why it was not.
    # The build's memory is the helper's, so it is gone once the helper ends, and the window plays
    # the game with none of it.
    #
    # WHAT THE HELPER SAYS, one JSON array a line (#message_line writes one):
    #
    #   ["step", name]            a phase of the build begins
    #   ["count", [done, total]]  where a phase that can be counted has got to
    #   ["detail", text]          what the phase is doing now
    #   ["written", path]         the game is written there; the helper ends
    #   ["refused", words]        the game cannot be played, in words for the player; the helper ends
    #
    # "written" or "refused" ends the watch, whether or not the pipe has closed: something the
    # build started may hold the pipe open long after the helper is gone.
    #
    # THE HELPER NEVER OUTLIVES THE WATCH. However the watch ends (the game written, a refusal, the
    # window closed, an error in the window's process), #stop_helper ends and reaps it: the window's
    # process calls it as it ends, and calling it again does nothing.
    #
    # Nothing else of the library is needed here, so the window's process loads none of it.
    class BuildWatch
      # How it ended: +written+, the path of the written game, or +refusal+, the words for why there
      # is none, or neither when the player stopped the window first.
      Outcome = Data.define(:written, :refusal) do
        def stopped? = written.nil? && refusal.nil?
      end

      FRAME_SECONDS = 1 / 60r # How long the window waits for the helper before it draws again
      ENDING_SECONDS = 2 # How long a helper that has said its last is given to end by itself
      TERM_SECONDS = 1 # How long a helper asked to end is given before it is killed

      KINDS = %w[step count detail written refused].freeze # What the helper says, by kind

      # One line of what the helper says.
      def self.message_line(kind, value) = "#{JSON.generate([kind, value])}\n"

      # THE WAIT WITH NO WINDOW, for a play that has none (a match with --no-window): it shows
      # nothing and never asks to stop, so the watch ends when the helper does. A refusal is said on
      # the terminal (#watch's +terminal+) and shown nowhere, so watch it with +refusal_frames+ 0.
      class Unseen
        def show_waiting(_lines) = nil
        def stop? = false
        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        def wait_until(_seconds) = nil
      end

      # +io+ is the helper's end of what it says, +pid+ the helper, and +title+ the game's, which
      # the window says it is building.
      def initialize(io, pid:, title:)
        @io = io
        @pid = pid
        @title = title
        @heard = +""
        @step = nil
        @where = nil
        @written = nil
        @refusal = nil
        @exit_status = nil
        @reaped = false
        @unreadable = false
      end

      # Shows +device+ what the helper is doing until it says its last, and gives back the Outcome.
      # A refusal is said on +terminal+ (an IO, or nil for none) as soon as it comes, then stays on
      # the device, said as the player reads it, until the device stops or +refusal_frames+ have
      # been shown (vblank run --pictures; nil for as long as it takes). The device asking to stop
      # while the helper works stops the helper.
      def watch(device, refusal_frames: nil, terminal: nil)
        until hear_last_message
          device.show_waiting(waiting_lines)
          if device.stop?
            stop_helper(grace: 0)
            return Outcome.new(written: nil, refusal: nil)
          end
        end
        stop_helper(grace: @unreadable ? 0 : ENDING_SECONDS)
        refuse_unsaid_end if @written.nil? && @refusal.nil?
        if @refusal
          terminal&.puts(@refusal)
          show_refusal(device, refusal_frames)
        end
        Outcome.new(written: @written, refusal: @refusal)
      end

      # Ends the helper, if it has not ended, and reaps it: given +grace+ seconds to end by itself,
      # then asked to (TERM), then killed. Done once; a second call does nothing.
      def stop_helper(grace: 0)
        return if @reaped

        @reaped = true
        @io.close unless @io.closed?
        status = wait_for_helper(grace)
        unless status
          signal_helper(:TERM)
          status = wait_for_helper(TERM_SECONDS)
        end
        unless status
          signal_helper(:KILL)
          status = Process.wait2(@pid).last
        end
        @exit_status = status.exitstatus
      rescue Errno::ECHILD
        nil
      end

      private

      # What the helper said in the next frame's time, taken in; true once it has said "written" or
      # "refused", or closed its end, or said something that is not one of its messages.
      def hear_last_message
        return false unless @io.wait_readable(FRAME_SECONDS)

        chunk = @io.read_nonblock(1 << 16, exception: false)
        return true if chunk.nil?
        return false if chunk == :wait_readable

        @heard << chunk
        while (line_end = @heard.index("\n"))
          take_message(@heard.slice!(0..line_end))
          return true if @written || @refusal
        end
        false
      end

      def take_message(line)
        kind, value = readable_message(line)
        case kind
        when "step"
          @step = value
          @where = nil
        when "count" then @where = value.join("/")
        when "detail" then @where = value
        when "written" then @written = value
        when "refused" then @refusal = value
        else
          # Not one of the helper's messages: the window cannot trust the rest, so the build ends here.
          @unreadable = true
          @refusal = "The build of #{@title} sent a line the window cannot read: #{line.strip[0, 80]}"
        end
      end

      # +line+ as [kind, value] when it is one of the helper's messages, else nil.
      def readable_message(line)
        kind, value = JSON.parse(line)
        [kind, value] if KINDS.include?(kind) && message_value?(kind, value)
      rescue JSON::ParserError
        nil
      end

      # Whether +value+ is what a message of +kind+ holds: two whole numbers for a count, else text.
      def message_value?(kind, value)
        return value.is_a?(Array) && value.size == 2 && value.all?(Integer) if kind == "count"

        value.is_a?(String)
      end

      # The helper ended saying neither where the game is nor why it is not.
      def refuse_unsaid_end
        @refusal = "The build of #{@title} stopped before it ended (exit status #{@exit_status.inspect}). " \
                   "The terminal shows what went wrong."
      end

      # The helper's exit status once it has ended, waiting up to +seconds+ for it; nil if it has not.
      def wait_for_helper(seconds)
        until_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          ended = Process.wait2(@pid, Process::WNOHANG)
          return ended.last if ended
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= until_time

          sleep 0.01
        end
      end

      def signal_helper(signal)
        Process.kill(signal, @pid)
      rescue Errno::ESRCH
        nil
      end

      def waiting_lines
        return ["Building #{@title}"] unless @step

        ["Building #{@title}", [@step, @where].compact.join("  ")]
      end

      # The refusal on the device, a frame at a time, until it stops or +frames+ have been shown.
      def show_refusal(device, frames)
        lines = ["#{@title} cannot play", *@refusal.split("\n")]
        shown = 0
        until device.stop? || (frames && shown >= frames)
          device.show_waiting(lines)
          shown += 1
          device.wait_until(device.now + FRAME_SECONDS)
        end
      end
    end
  end
end
