# frozen_string_literal: true

module VBlank
  module Network
    # THE STAND-IN RELAY WITH A WEBSOCKET FACE: it listens on a TCP port, turns each connection into a
    # WebSocket (the server's half of the handshake), and gives the messages to a StandInRelay and the relay's
    # messages back, as the real relay does. A test starts one in a thread of its own, and another program (a
    # node copy of a game, a desktop build) connects to it from outside (tools/stand_in_relay.rb runs one on
    # its own).
    #
    # It is one loop that looks at every socket in turn, so it needs no locks, and a client that is slow only
    # makes itself wait: nothing in the loop reads in a way that waits, the handshake included. It speaks `ws://`; the real relay will be `wss://`, and what a client does about TLS is
    # tested apart from this.
    class StandInRelayServer
      attr_reader :port, :relay

      # +port+ 0 lets the system choose, and #port says which it chose.
      def initialize(relay: StandInRelay.new, host: "127.0.0.1", port: 0)
        @relay = relay
        @listener = TCPServer.new(host, port)
        @port = @listener.addr[1]
        @peers = []
        @stop_reader, @stop_writer = IO.pipe
      end

      # The address a client connects to.
      def url = "ws://127.0.0.1:#{port}/"

      # Serves in a thread of its own until #stop. Gives back the thread.
      def start
        @thread = Thread.new { serve }
        self
      end

      # Stops serving, closes every connection, and waits for the thread to end.
      def stop
        @stop_writer.write("x")
        @thread&.join
        @listener.close unless @listener.closed?
        @stop_reader.close
        @stop_writer.close
      end

      # The longest a connection may take to send its whole handshake before it is closed.
      HANDSHAKE_SECONDS = 10

      private

      Peer = Data.define(:socket, :connection)

      # A connection whose handshake has not all come yet: its socket, the bytes so far, and when it connected.
      Greeting = Struct.new(:io, :bytes, :since)

      # A CLIENT THAT SAYS NOTHING MAKES NOBODY WAIT. A handshake is read a piece at a time as it comes, in the one
      # loop that serves every socket, never with a read that waits; one that has not all come in HANDSHAKE_SECONDS
      # is closed.
      def serve
        @greetings = []
        loop do
          readable, = IO.select([@listener, @stop_reader, *@greetings.map(&:io), *@peers.map { |peer| peer.socket.io }],
                                nil, nil, @greetings.empty? ? nil : 1)
          readable ||= []
          break if readable.include?(@stop_reader)

          accept_waiting if readable.include?(@listener)
          @greetings.dup.each { |greeting| read_greeting(greeting) if readable.include?(greeting.io) }
          close_slow_greetings
          @peers.each { |peer| carry_to_relay(peer) }
          @peers.each { |peer| carry_from_relay(peer) }
          gone, @peers = @peers.partition { |peer| peer.socket.ended? && peer.connection.closed? }
          gone.each { |peer| peer.socket.close } # the client has gone, so this end closes too
        end
        @greetings.each { |greeting| greeting.io.close }
        @peers.each { |peer| peer.socket.close }
      end

      def accept_waiting
        loop { @greetings << Greeting.new(@listener.accept_nonblock, "".b, now) }
      rescue IO::WaitReadable
        nil
      end

      # Reads what a connection has sent of its handshake, and answers it once it has all come.
      def read_greeting(greeting)
        greeting.bytes << greeting.io.read_nonblock(1024)
        head, rest = WebSocket::Handshake.split_head(greeting.bytes)
        return unless head

        @greetings.delete(greeting)
        @peers << Peer.new(socket: WebSocket::ServerPeer.answer(greeting.io, head, rest), connection: @relay.connect)
      rescue IO::WaitReadable
        nil
      rescue WebSocket::HandshakeFailed, EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError
        @greetings.delete(greeting)
        greeting.io.close unless greeting.io.closed?
      end

      def close_slow_greetings
        slow, @greetings = @greetings.partition { |greeting| now - greeting.since > HANDSHAKE_SECONDS }
        slow.each { |greeting| greeting.io.close }
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def carry_to_relay(peer)
        peer.socket.read_messages.each { |text| peer.connection.send_text(text) }
        peer.connection.close if peer.socket.ended?
      end

      def carry_from_relay(peer)
        while (text = peer.connection.receive_text)
          peer.socket.send_text(text)
        end
      end
    end
  end
end
