# frozen_string_literal: true

module VBlank
  module Network
    module WebSocket
      # A CLIENT OF A WEBSOCKET SERVER, as the server sees it: the other end of a Client. It does the server's
      # half of the handshake and then turns bytes into messages and messages into frames. The stand-in
      # relay's server (StandInRelayServer) is made of these, and so are the tests of Client.
      #
      # It never blocks on its own: #read_messages takes what has arrived, and the caller decides when to look.
      class ServerPeer
        attr_reader :io, :path

        # Does the handshake on +io+, which a client has just connected: reads its request and answers it.
        # Raises HandshakeFailed when what came is not a WebSocket request.
        def self.accept(io)
          head, rest = Handshake.read_head(io)
          request, headers = Handshake.parse(head)
          key = headers["sec-websocket-key"]
          unless request.start_with?("GET ") && headers["upgrade"].to_s.casecmp?("websocket") && key
            io.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            raise HandshakeFailed, "That was not a WebSocket request."
          end
          io.write(Handshake.response(key))
          new(io, request.split[1], rest)
        end

        def initialize(io, path, first_bytes = "")
          @io = io
          @path = path
          @reader = Reader.new
          @reader.feed(first_bytes)
          @pieces = nil
          @ended = false
        end

        def ended? = @ended

        # The text messages that have arrived since the last call, in order. A ping is answered, and a close is
        # answered and ends the peer.
        def read_messages
          messages = []
          return messages if @ended

          begin
            loop do
              @reader.feed(@io.read_nonblock(4096))
              collect(messages)
            end
          rescue IO::WaitReadable
            collect(messages)
          rescue EOFError, Errno::ECONNRESET, IOError
            collect(messages)
            @ended = true
          rescue ProtocolError
            @ended = true
          end
          messages
        end

        def send_text(text) = write(Framing.encode(:text, text.b))

        def ping(payload = "") = write(Framing.encode(:ping, payload))

        def close
          write(Framing.encode(:close, Framing.close_payload(CLOSE_NORMAL))) unless @ended
          @ended = true
          @io.close unless @io.closed?
        end

        private

        def write(bytes)
          @io.write(bytes)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          @ended = true
        end

        def collect(messages)
          while (frame = @reader.next_frame)
            case frame.opcode
            when :text then @pieces = frame.payload.dup
            when :continuation then @pieces&.<<(frame.payload)
            when :ping then write(Framing.encode(:pong, frame.payload))
            when :close then answer_close(frame)
            end
            next unless %i[text continuation].include?(frame.opcode) && frame.fin && @pieces

            messages << @pieces.force_encoding(Encoding::UTF_8)
            @pieces = nil
          end
        end

        def answer_close(frame)
          write(Framing.encode(:close, frame.payload.byteslice(0, 2).to_s)) unless @ended
          @ended = true
        end
      end
    end
  end
end
