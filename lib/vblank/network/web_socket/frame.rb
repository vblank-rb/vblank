# frozen_string_literal: true

module VBlank
  module Network
    # A WEBSOCKET (RFC 6455) FOR A GAME THAT HAS NO GEMS TO TAKE ONE FROM. Ruby's standard library has
    # no WebSocket client, and the framework stays pure Ruby, so this is the small part of the protocol a
    # match needs: the opening handshake over HTTP, messages in frames, ping and close. It talks to the relay
    # (a WebSocket server) over a TCP socket, or a TLS one for `wss://`. It is not a general WebSocket: it
    # does not compress, and it keeps only text messages.
    module WebSocket
      # The text the opening handshake mixes into the client's key to make the server's answer.
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

      # What a frame can be, by its number on the wire.
      OPCODES = { continuation: 0, text: 1, binary: 2, close: 8, ping: 9, pong: 10 }.freeze

      # The largest message this reads, so a peer cannot make it hold the whole memory. A match's messages
      # are a few dozen bytes, and the relay's are as small.
      MOST_PAYLOAD_BYTES = 1 << 20

      # The code a close carries when nothing went wrong, and when the peer broke the protocol.
      CLOSE_NORMAL = 1000
      CLOSE_PROTOCOL_ERROR = 1002

      # A frame: whether it ends its message, what kind it is (a key of OPCODES), and its bytes.
      Frame = Data.define(:fin, :opcode, :payload)

      # A peer that broke the rules of the protocol, said in plain words.
      class ProtocolError < StandardError; end

      # FRAMES AS BYTES AND BACK. A frame is two bytes (whether it is the last of its message, which kind
      # it is, whether its bytes are masked, and how long they are), then the length if it is more than 125
      # bytes, then the four bytes of the mask if there is one, then the bytes. A client masks every frame it
      # sends, with a mask it chooses, and a server never does.
      module Framing
        module_function

        # The bytes of one frame. +mask_key+ is four bytes to mask with, or nil for none; a client always
        # gives one, which is a random one unless a test gives it.
        def encode(opcode, payload, mask_key: nil, fin: true)
          payload = payload.b
          first = (fin ? 0x80 : 0) | OPCODES.fetch(opcode)
          head = [first].pack("C") + length_bytes(payload.bytesize, masked: !mask_key.nil?)
          return head + payload unless mask_key

          head + mask_key.b + mask(payload, mask_key)
        end

        def client_mask_key = SecureRandom.random_bytes(4)

        # +bytes+ with every fourth byte changed by the key, which is how a mask is put on and taken off.
        def mask(bytes, key)
          key_bytes = key.bytes
          bytes.bytes.each_with_index.map { |byte, index| byte ^ key_bytes[index % 4] }.pack("C*")
        end

        def length_bytes(length, masked:)
          flag = masked ? 0x80 : 0
          if length < 126 then [flag | length].pack("C")
          elsif length < 65_536 then [flag | 126, length].pack("Cn")
          else [flag | 127, length].pack("CQ>")
          end
        end

        # The close message's bytes: a code and the words for it.
        def close_payload(code, words = "") = [code].pack("n") + words.b
      end

      # WHAT HAS ARRIVED, A FRAME AT A TIME. Bytes come in whatever pieces the network cuts them into; #feed
      # takes them and #next_frame gives back a whole frame once there is one, and nil until then.
      class Reader
        def initialize
          @buffer = "".b
        end

        def feed(bytes) = @buffer << bytes.b

        def next_frame
          return nil if @buffer.bytesize < 2

          first, second = @buffer.unpack("CC")
          found = payload_length(second & 0x7F) or return nil

          length, head = found
          masked = second.anybits?(0x80)
          total = head + (masked ? 4 : 0) + length
          return nil if @buffer.bytesize < total

          build_frame(first, masked, head, length, total)
        end

        private

        # How many bytes the payload is, and how many bytes the head took up to and including its length.
        def payload_length(code)
          return [code, 2] if code < 126

          width = code == 126 ? 2 : 8
          return nil if @buffer.bytesize < 2 + width

          length = @buffer.byteslice(2, width).unpack1(code == 126 ? "n" : "Q>")
          raise ProtocolError, "A message of #{length} bytes is more than this reads (#{MOST_PAYLOAD_BYTES})." if length > MOST_PAYLOAD_BYTES

          [length, 2 + width]
        end

        def build_frame(first, masked, head, length, total)
          raise ProtocolError, "A frame used bits this does not know." if first.anybits?(0x70)

          opcode = OPCODES.key(first & 0x0F) or raise ProtocolError, "A frame had a kind this does not know (#{first & 0x0F})."
          key = masked ? @buffer.byteslice(head, 4) : nil
          payload = @buffer.byteslice(head + (masked ? 4 : 0), length)
          @buffer = @buffer.byteslice(total, @buffer.bytesize - total)
          Frame.new(fin: first.anybits?(0x80), opcode: opcode, payload: key ? Framing.mask(payload, key) : payload)
        end
      end
    end
  end
end
