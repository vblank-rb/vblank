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
    # makes itself wait. It speaks `ws://`; the real relay will be `wss://`, and what a client does about TLS is
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

      private

      Peer = Data.define(:socket, :connection)

      def serve
        loop do
          readable, = IO.select([@listener, @stop_reader, *@peers.map { |peer| peer.socket.io }])
          break if readable.include?(@stop_reader)

          accept_one if readable.include?(@listener)
          @peers.each { |peer| carry_to_relay(peer) }
          @peers.each { |peer| carry_from_relay(peer) }
          @peers.reject! { |peer| peer.socket.ended? && peer.connection.closed? }
        end
        @peers.each { |peer| peer.socket.close }
      end

      def accept_one
        io = @listener.accept
        @peers << Peer.new(socket: WebSocket::ServerPeer.accept(io), connection: @relay.connect)
      rescue WebSocket::HandshakeFailed, EOFError, Errno::ECONNRESET
        io&.close
      end

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
