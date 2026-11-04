# frozen_string_literal: true

module VBlank
  module Network
    # PLAYING THROUGH A RELAY, which is what `vblank run --relay --host` and `--relay --join CODE` do: each
    # machine connects out to the relay over a WebSocket, so nobody has to open a port or know another's
    # address. One machine makes a room and is told its code, and gives the code to the others, who join it.
    #
    # THE RELAY'S ADDRESS IS ONE SETTING (RELAY_URL_VARIABLE, or the address given to --relay). There is no
    # default: the real relay has no address yet. Anything else reads it from here.
    module RelayPlay
      # The environment variable that holds the relay's address when none is given.
      RELAY_URL_VARIABLE = "VBLANK_RELAY_URL"

      module_function

      # The relay's address: +given+ if it says one, else the environment's. Raises ConnectionFailed in
      # plain words when neither does.
      def url_from(given, environment: ENV)
        url = given.to_s.empty? ? environment[RELAY_URL_VARIABLE].to_s : given
        return url unless url.empty?

        raise ConnectionFailed, "No relay address is set. To fix this, give it with --relay ws://HOST/PATH, or set the " \
                                "#{RELAY_URL_VARIABLE} variable."
      end

      # Makes a room on the relay at +url+. Gives back [lockstep, code]: the host's side of a match for +players+,
      # to be begun, and the room's code for the others.
      def host(url, players:, input_delay:, fingerprint:, seed: Random.rand(1 << 31))
        transport = RelayTransport.make_room(WebSocket::Client.connect(url))
        lockstep = Lockstep.host(transport: transport, fingerprint: fingerprint, players: players, seed: seed,
                                 input_delay: input_delay)
        [lockstep, transport.code]
      rescue WebSocket::HandshakeFailed => e
        raise ConnectionFailed, e.message
      end

      # Joins the room that has +code+ on the relay at +url+. The lockstep has not begun.
      def join(url, code, fingerprint:)
        transport = RelayTransport.join_room(WebSocket::Client.connect(url), code)
        Lockstep.join(transport: transport, fingerprint: fingerprint)
      rescue WebSocket::HandshakeFailed, RoomRefused => e
        raise ConnectionFailed, e.message
      end
    end
  end
end
