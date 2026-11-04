# frozen_string_literal: true

module VBlank
  module Network
    # CLOSING A SOCKET WITHOUT LOSING WHAT WAS SENT LAST. A socket closed while it still holds bytes the other end
    # sent and this end never read is not closed politely: the system resets the connection, and a reset can make the
    # other end drop what this end sent just before, which here is a player's last buttons. A machine in a match is
    # always being sent something, so a plain close would lose its last messages now and then, and the others would
    # see it leave a few passes early.
    #
    # So this end says it has finished sending (a shutdown of its half), reads and drops what still comes until the
    # other end closes too, and only then closes. A peer that never closes is given LINGER_SECONDS.
    module SocketEnd
      LINGER_SECONDS = 2
      READ_BYTES = 4096

      module_function

      def close(io)
        return if io.closed?

        linger(io) if io.is_a?(BasicSocket)
      rescue IOError, SystemCallError
        nil
      ensure
        io.close unless io.closed?
      end

      def linger(socket)
        socket.shutdown(Socket::SHUT_WR)
        deadline = now + LINGER_SECONDS
        loop do
          read = socket.read_nonblock(READ_BYTES, exception: false)
          break if read.nil? # the other end has closed

          next unless read == :wait_readable

          left = deadline - now
          break if left <= 0 || !IO.select([socket], nil, nil, left)
        end
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
