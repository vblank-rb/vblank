# frozen_string_literal: true

module VBlank
  module Network
    # Text, a line at a time, over an open socket (TCP, or a pair of UNIX sockets in a test): one message is
    # one line. It answers what a RelayTransport asks of any line, as a WebSocket does for the relay:
    # send_text, receive_text, wait_for_text, close and closed?.
    #
    # Nothing here waits for longer than it is asked. Reading never blocks (a message is what is there
    # so far), and #wait_for_text sleeps only inside IO.select, which wakes the moment a byte arrives or the
    # other end goes away. A peer that went away, however it did (a closed window, a killed process, a
    # reset connection), is the same thing here: the line is closed once everything it sent has been
    # read. Messages sent before the end are never lost to it.
    #
    # ### A peer that goes silent
    #
    # A cable pulled out, or a machine that froze, sends no end at all, and TCP alone would wait many
    # minutes before it gave up. So each end sends an empty line every +beat_seconds+, from a thread of its
    # own, whatever the game is doing: a machine whose window is paused, or that is waiting on the others,
    # still says it is there. An empty line carries no message and is never handed on. A line that has
    # heard nothing at all, not even an empty line, for +silent_seconds+ is closed, as though the peer had
    # closed it. How much it heard before then is all it reads.
    #
    # Writing never blocks either. What the socket will not take yet waits here, and goes with the next
    # write or beat; a peer that has not read MOST_WAITING_BYTES of it has stopped reading, and the line
    # is closed.
    class LineChannel
      READ_BYTES = 4096

      # The longest line this keeps while it waits for the line's end. A match's messages are a few dozen bytes;
      # a peer that sends more than this and no end of line is not speaking the format, and would otherwise fill
      # the memory, so the line is closed.
      MOST_LINE_BYTES = 1 << 16

      # The most bytes kept for a peer that is not reading them. A match sends a few dozen bytes a pass, and a
      # pass waits for every machine, so a peer this far behind is not reading at all.
      MOST_WAITING_BYTES = 1 << 20

      # How often an end says it is still there, in seconds.
      BEAT_SECONDS = 1

      # How long a line waits, hearing nothing at all, before it takes the peer to have gone. Several beats,
      # so a slow network that holds a few of them back does not end the match.
      SILENT_SECONDS = 10

      attr_reader :io

      # +silent_seconds+ and +beat_seconds+ are SILENT_SECONDS and BEAT_SECONDS but in a test, which gives
      # short ones so a silent peer is found at once.
      def initialize(io, silent_seconds: SILENT_SECONDS, beat_seconds: BEAT_SECONDS)
        @io = io
        @buffer = +""
        @lines = []
        @ended = false
        @silent_seconds = silent_seconds
        @last_heard = now
        @waiting = +"".b # what the socket would not take yet
        @writing = Mutex.new
        @shut = false # closed by this end, which is done once
        send_each_line_at_once(io) if io.is_a?(TCPSocket)
        @beat_stop = Queue.new # something put here stops the beat
        @beat = start_beat(beat_seconds)
      end

      # TCP holds a small write back to send it with the next (Nagle's rule), and the other end holds
      # back its acknowledgement of it, so a line of a few bytes can wait tens of milliseconds before
      # it leaves. A match sends one such line every pass and waits for the other machines' lines, so
      # every line goes out as it is written.
      private def send_each_line_at_once(io)
        io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
      end

      # One line for +text+. A write to a peer that has gone ends the line instead of raising.
      def send_text(text) = write_line(text)

      # The next whole line that has arrived, or nil.
      def receive_text
        read_what_has_arrived
        @lines.shift
      end

      def pending?
        read_what_has_arrived
        !@lines.empty?
      end

      # True once the other end has gone and every line it sent has been read.
      def closed?
        read_what_has_arrived
        @ended && @lines.empty?
      end

      # Returns true when there is a line to read or the line is closed, and false when +seconds+ went by
      # first: the longest to wait, for a caller that has other things to look at; nil waits for the socket
      # however long that is, or until the peer has been silent too long. A byte that is not yet a whole
      # line wakes the select but not the caller.
      #
      # The socket is read once a look, as WebSocket::Client#wait_for_text says why.
      def wait_for_text(seconds = nil)
        deadline = seconds && (now + seconds)
        loop do
          return true if ready?

          left = deadline && (deadline - now)
          return false if left && left <= 0

          IO.select([@io], nil, nil, [left, seconds_until_silent].compact.min)
        end
      end

      # Whether a caller has something to do: a line to read, or the end to notice. One read of the socket.
      def ready?
        read_what_has_arrived
        @ended || !@lines.empty?
      end

      # How long this line can still hear nothing before it takes the peer to have gone: the longest a
      # caller sleeps on its socket before it looks again (DirectRoom#wait_for_traffic).
      def seconds_until_silent = [@last_heard + @silent_seconds - now, 0].max

      # Ends the line without losing what was sent on it last: the beat is stopped first, so it cannot
      # send a line twice, then what the socket has not taken yet is sent, waiting up to
      # CLOSE_FLUSH_SECONDS for it (the room's last lines to a peer, its news that a player left above
      # all), and the socket is closed politely (SocketEnd). Closing again does nothing.
      def close
        return if @shut

        @shut = true
        stop_beat
        @writing.synchronize do
          @ended = true
          flush_waiting(CLOSE_FLUSH_SECONDS)
        end
        SocketEnd.close(@io)
      end

      # The longest a close waits for the socket to take what is waiting, in seconds.
      CLOSE_FLUSH_SECONDS = 2

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The thread that sends an empty line every +seconds+, until #stop_beat.
      def start_beat(seconds)
        Thread.new do
          Thread.current.report_on_exception = false
          write_line("") while @beat_stop.pop(timeout: seconds).nil?
        end
      end

      # Stops the beat and waits for it to end, so it is never part way through a write.
      def stop_beat
        @beat_stop << true
        @beat.join
      end

      # The peer said nothing for too long: the line ends, and its socket is let go at once, with no
      # polite close, since nobody is there to answer one.
      def end_silent_line
        @shut = true
        stop_beat
        @writing.synchronize { @ended = true }
        @io.close
      end

      # The line and whatever was waiting, as much as the socket takes now. The beat's thread writes too.
      def write_line(text)
        @writing.synchronize do
          return if @ended

          @waiting << text.b << "\n"
          flush_waiting
          @ended = true if @waiting.bytesize > MOST_WAITING_BYTES
        end
      end

      # As much of what is waiting as the socket takes, waiting up to +seconds+ for it to take more.
      def flush_waiting(seconds = 0)
        deadline = now + seconds
        until @waiting.empty?
          written = @io.write_nonblock(@waiting, exception: false)
          if written == :wait_writable
            left = deadline - now
            return if left <= 0 || !IO.select(nil, [@io], nil, left)

            next
          end
          @waiting = @waiting.byteslice(written..)
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @ended = true
      end

      # Everything the socket holds now, split into lines, empty lines left out. The end of the socket is
      # noticed here, a line too long to keep, which closes it (the whole lines before it can still be read),
      # and a peer silent too long.
      def read_what_has_arrived
        return if @ended || @io.closed?

        loop do
          @buffer << @io.read_nonblock(READ_BYTES)
          @last_heard = now
          @lines.concat(@buffer.slice!(0, @buffer.rindex("\n") + 1).split("\n").reject(&:empty?)) if @buffer.include?("\n")
          next unless @buffer.bytesize > MOST_LINE_BYTES

          @buffer.clear
          return close
        end
      rescue IO::WaitReadable
        # The silence is counted from when this end last read something, not from when it came: an end
        # that was itself held (a window paused, a machine that froze) reads what came meanwhile first,
        # and counts again from there, so it gives a peer that went at that time the whole of
        # +silent_seconds+ again before it takes it to have gone.
        end_silent_line if now - @last_heard >= @silent_seconds
      rescue EOFError, Errno::ECONNRESET, IOError
        @ended = true
      end
    end
  end
end
