# frozen_string_literal: true

require "socket"

module VBlank
  module Network
    # PLAYING WITH A MACHINE YOU CAN REACH BY ADDRESS, which is what `vblank run --host` and `--join` do:
    # one machine listens on a TCP port and hosts the match (DirectRoom), and the others connect to its address
    # and join it. Nothing is in between and nothing is asked of a relay. The lockstep that comes back has not
    # started yet; its #begin_match waits for the players.
    module DirectPlay
      # The port a host listens on when it is not told one.
      DEFAULT_PORT = 7777

      # Where a host is: a name or an address, and a port.
      Address = Data.define(:host, :port) do
        # The address in +text+, written HOST:PORT, or just HOST for the default port.
        def self.parse(text)
          host, port = text.to_s.split(":", 2)
          raise ArgumentError, bad_address(text) if host.to_s.empty? || (port && !port.match?(/\A\d+\z/)) || (port && !port.to_i.between?(1, 65_535))

          new(host: host, port: port ? port.to_i : DEFAULT_PORT)
        end

        def self.bad_address(text)
          "#{text.inspect} is not an address. Write it as HOST:PORT, for example 192.168.1.5:7777, or just the host " \
            "for port #{DEFAULT_PORT}. To fix this, ask the host for its address."
        end
        private_class_method :bad_address

        def to_s = "#{host}:#{port}"
      end

      module_function

      # Starts listening on +port+ (0 lets the system choose) and gives back [lockstep, port]: the host's
      # side of a match for +players+, to be begun, and the port it listens on.
      def host(port:, players:, input_delay:, fingerprint:, seed: Random.rand(1 << 31))
        listener = TCPServer.new("0.0.0.0", port)
        transport = RelayTransport.make_room(DirectRoom.new(listener: listener).host_line)
        lockstep = Lockstep.host(transport: transport, fingerprint: fingerprint, players: players, seed: seed,
                                 input_delay: input_delay)
        [lockstep, listener.addr[1]]
      rescue Errno::EADDRINUSE
        raise ConnectionFailed, "Port #{port} is in use already. To fix this, host on another port, for example " \
                                "--host #{port + 1}."
      rescue Errno::EACCES
        raise ConnectionFailed, "This computer does not let VBlank listen on port #{port}. To fix this, host on a port " \
                                "above 1024."
      end

      # Connects to the host at +address+ and joins its match, which has not started: give the lockstep back
      # to begin it.
      def join(address, fingerprint:)
        socket = TCPSocket.new(address.host, address.port)
        transport = RelayTransport.join_room(LineChannel.new(socket), DirectRoom::CODE)
        Lockstep.join(transport: transport, fingerprint: fingerprint)
      rescue Errno::ECONNREFUSED
        raise ConnectionFailed, "Nobody is hosting at #{address}. To fix this, check the address, and make sure the " \
                                "host has started with --host."
      rescue SocketError
        raise ConnectionFailed, "This computer cannot find #{address.host}. To fix this, check the address."
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT
        raise ConnectionFailed, "This computer cannot reach #{address}. To fix this, check the address and the network."
      end

      # The addresses another machine on this network can reach this one at, for a host to say. The
      # loopback address is last, since only this machine can use it.
      def addresses_for(port)
        found = Socket.ip_address_list.select { |each| each.ipv4? && !each.ipv4_loopback? }.map { |each| "#{each.ip_address}:#{port}" }
        found + ["127.0.0.1:#{port}"]
      end
    end

    # A connection that could not be made, in plain words.
    class ConnectionFailed < StandardError; end
  end
end
