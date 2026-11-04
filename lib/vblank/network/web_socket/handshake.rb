# frozen_string_literal: true

module VBlank
  module Network
    module WebSocket
      # The relay did not accept the connection as a WebSocket, said in plain words.
      class HandshakeFailed < StandardError; end

      # THE OPENING HANDSHAKE: an HTTP request that asks to turn the connection into a WebSocket, and the
      # answer that agrees. The client sends a random key; the server proves it understood by sending back a
      # number made from that key and a fixed text (GUID), so a server that is not a WebSocket one, or a
      # cache that replays an old answer, cannot pass for one.
      module Handshake
        module_function

        # The request a client sends to +host+ for +path+. +key+ is 16 random bytes, as base64.
        def request(host, path, key)
          "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        end

        def new_key = [SecureRandom.random_bytes(16)].pack("m0")

        # The answer a server gives to a request with +key+.
        def accept_for(key) = [Digest::SHA1.digest(key + GUID)].pack("m0")

        def response(key)
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Accept: #{accept_for(key)}\r\n\r\n"
        end

        # The headers of an HTTP message, lowercased by name, and its first line.
        def parse(head)
          first, *lines = head.split("\r\n")
          headers = lines.filter_map { |line| line.split(":", 2).then { |name, value| [name.strip.downcase, value.strip] if value } }.to_h
          [first.to_s, headers]
        end

        # Reads from +io+ until the blank line that ends an HTTP head. Gives back the head and the bytes that came
        # after it, which are the start of the first frames.
        def read_head(io)
          buffer = "".b
          until (at = buffer.index("\r\n\r\n"))
            chunk = io.readpartial(1024) # raises EOFError when the other end goes
            buffer << chunk
            raise HandshakeFailed, "The other end sent a very long answer where the handshake was to be." if buffer.bytesize > 16_384
          end
          [buffer.byteslice(0, at), buffer.byteslice(at + 4, buffer.bytesize - at - 4)]
        end

        # Checks the server's answer to a request with +key+; raises HandshakeFailed in plain words.
        def check_response!(head, key, address)
          status, headers = parse(head)
          code = status[%r{\AHTTP/1\.[01] (\d{3})}, 1]
          unless code == "101"
            raise HandshakeFailed, "The relay at #{address} did not accept a WebSocket connection (it said #{code ? "HTTP #{code}" : status.inspect}). " \
                                   "To fix this, check the relay address."
          end
          return if headers["upgrade"].to_s.casecmp?("websocket") && headers["sec-websocket-accept"] == accept_for(key)

          raise HandshakeFailed, "The relay at #{address} answered, but not as a WebSocket does. To fix this, check that the address is " \
                                 "the relay's WebSocket address."
        end
      end
    end
  end
end
