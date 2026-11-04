# frozen_string_literal: true

module VBlank
  module Network
    # TEXT, A LINE AT A TIME, OVER AN OPEN SOCKET (TCP, or a pair of UNIX sockets in a test): one message is
    # one line. It answers what a RelayTransport asks of any line, as a WebSocket does for the relay:
    # send_text, receive_text, wait_for_text, close and closed?.
    #
    # NOTHING HERE WAITS FOR LONGER THAN IT IS ASKED. Reading never blocks (a message is what is there
    # so far), and #wait_for_text sleeps only inside IO.select, which wakes the moment a byte arrives or the
    # other end goes away. A peer that went away, however it did (a closed window, a killed process, a
    # reset connection), is the same thing here: the line is closed once everything it sent has been
    # read. Messages sent before the end are never lost to it.
    #
    # A cable pulled out or a machine that froze sends no end at all. TCP keepalive is turned on so that the
    # operating system in the end gives up and the connection resets; how long that takes is the system's.
    class LineChannel
      READ_BYTES = 4096

      # The longest line this keeps while it waits for the line's end. A match's messages are a few dozen bytes;
      # a peer that sends more than this and no end of line is not speaking the format, and would otherwise fill
      # the memory, so the line is closed.
      MOST_LINE_BYTES = 1 << 16

      attr_reader :io

      def initialize(io)
        @io = io
        @buffer = +""
        @lines = []
        @ended = false
        io.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true) if io.is_a?(TCPSocket)
      end

      # One line for +text+. A write to a peer that has gone ends the line instead of raising.
      def send_text(text)
        return if @ended

        @io.write("#{text}\n")
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @ended = true
      end

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

      # Returns when there is a line to read, or the line is closed. +seconds+ is the longest to wait, for a
      # caller that has other things to look at; nil waits for the socket however long that is. A byte that is
      # not yet a whole line wakes the select but not the caller: the wait goes on until the deadline.
      def wait_for_text(seconds = nil)
        deadline = seconds && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)
        until pending? || closed?
          left = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          return if left && left <= 0

          IO.select([@io], nil, nil, left)
        end
      end

      # Ends the line without losing what was sent on it last (SocketEnd).
      def close
        @ended = true
        SocketEnd.close(@io)
      end

      private

      # Everything the socket holds now, split into lines. The end of the socket is noticed here, and so is a line
      # too long to keep, which closes it: the whole lines before it can still be read.
      def read_what_has_arrived
        return if @ended || @io.closed?

        loop do
          @buffer << @io.read_nonblock(READ_BYTES)
          @lines.concat(@buffer.slice!(0, @buffer.rindex("\n") + 1).split("\n")) if @buffer.include?("\n")
          next unless @buffer.bytesize > MOST_LINE_BYTES

          @buffer.clear
          return close
        end
      rescue IO::WaitReadable
        nil
      rescue EOFError, Errno::ECONNRESET, IOError
        @ended = true
      end
    end
  end
end
