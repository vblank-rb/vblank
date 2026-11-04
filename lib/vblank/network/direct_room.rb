# frozen_string_literal: true

module VBlank
  module Network
    # THE HOST OF A DIRECT CONNECTION IS A RELAY. It takes the machines that connect to it, puts them in one
    # room, and hands each message on to the others, exactly as a relay does (it is the same room, StandInRelay),
    # so the machine that hosts and the machines that join all speak the format they would speak to a relay and
    # cannot tell the difference. The host's own machine is one more member of the room: #host_line is its link.
    #
    # A machine that joins connects a socket (TCP, or a UNIX socket in a test) and joins the one room, which
    # has a fixed code (CODE), since the address already says which room. The host is player 1 and the others
    # are numbered as they arrive.
    #
    # NOTHING HERE RUNS ON ITS OWN. The room moves text between its sockets and its relay when the host's
    # machine looks for a message or waits for one (#pump, called by HostLine), which is also when a
    # machine that has connected is accepted. A machine that is slow to look makes the others wait for the
    # messages it holds, and that is the cost of one machine being the room.
    class DirectRoom
      # The code of the only room, which a machine joins to join the match.
      CODE = "DIRECT"

      # A machine on a socket, and its place in the relay.
      Peer = Data.define(:channel, :connection)

      # +listener+ is a TCPServer to accept machines from, or nil to give machines one at a time with #add_client.
      def initialize(listener: nil)
        @listener = listener
        @relay = StandInRelay.new(codes: [CODE].each)
        @peers = []
      end

      # The host's own link to the room, which a RelayTransport makes the room on. Make the room before
      # any machine joins.
      def host_line = @host_line ||= HostLine.new(self, @relay.connect)

      # Puts the machine on +socket+ in the room, as one that connected.
      def add_client(socket)
        @peers << Peer.new(channel: LineChannel.new(socket), connection: @relay.connect)
      end

      # Moves what is waiting between the sockets and the room, and accepts the machines waiting to connect.
      # Never waits.
      def pump
        accept_waiting
        @peers.each { |peer| carry_to_room(peer) }
        @peers.each { |peer| carry_from_room(peer) }
        @peers.reject! { |peer| peer.channel.closed? && peer.connection.closed? }
      end

      # Sleeps until a socket has something for the room, then pumps. A line a channel has already read
      # off its socket is something too: the socket is empty then, and would never wake the sleep.
      def wait_for_traffic
        sockets = @peers.map { |peer| peer.channel.io }.reject(&:closed?)
        sockets << @listener if @listener
        IO.select(sockets) unless sockets.empty? || @peers.any? { |peer| peer.channel.pending? || peer.channel.closed? }
        pump
      end

      # Ends the match for everybody: the sockets are closed, and the machines on them see the end.
      def close
        @peers.each { |peer| peer.channel.close }
        @listener&.close
      end

      private

      def accept_waiting
        return unless @listener

        loop { add_client(@listener.accept_nonblock) }
      rescue IO::WaitReadable
        nil
      end

      # A machine's lines go to the room; a machine that has gone leaves it, which the others are told.
      def carry_to_room(peer)
        while (text = peer.channel.receive_text)
          peer.connection.send_text(text)
        end
        peer.connection.close if peer.channel.closed?
      end

      def carry_from_room(peer)
        while (text = peer.connection.receive_text)
          peer.channel.send_text(text)
        end
      end

      # The host machine's link to the room it hosts: text in and out of the relay, with a wait that
      # serves the sockets meanwhile.
      class HostLine
        def initialize(room, connection)
          @room = room
          @connection = connection
        end

        def send_text(text) = @connection.send_text(text)

        def receive_text
          @room.pump
          @connection.receive_text
        end

        def close
          @connection.close
          @room.pump
          @room.close
        end

        def closed? = @connection.closed?

        def wait_for_text
          @room.pump
          @room.wait_for_traffic until @connection.pending? || @connection.closed?
        end
      end
    end
  end
end
