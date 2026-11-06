# frozen_string_literal: true

module VBlank
  module Network
    module WebSocket
      # A WEBSOCKET CONNECTION AS A MACHINE USES IT: text goes in as messages and comes out as messages. It
      # answers what a RelayTransport asks of any line: send_text, receive_text, wait_for_text, close, closed?
      # (and pending?).
      #
      # NOTHING WAITS FOR LONGER THAN IT IS ASKED. Reading never blocks; #wait_for_text sleeps only in IO.select,
      # which wakes when a byte comes or the other end goes. A ping is answered with a pong as it is read, so the
      # relay does not take a machine for gone while it waits on a pass. A close from the relay is answered and
      # ends the connection once the messages before it have been read, as a socket's end does (LineChannel).
      #
      # Only TEXT messages are kept (the format is text). A message sent in pieces is joined.
      class Client
        # Connects to the relay at +url+ (`ws://host:port/path`, or `wss://` for TLS, which checks the relay's
        # certificate and name) and does the opening handshake. +ssl_context+ is for a test to say whom to
        # trust; it is the system's own by default.
        def self.connect(url, ssl_context: nil)
          uri = URI.parse(url)
          unless %w[ws wss].include?(uri.scheme) && uri.host
            raise HandshakeFailed, "#{url.inspect} is not a relay address. A relay address starts with ws:// or wss://. " \
                                   "To fix this, check the address."
          end

          port = uri.port || (uri.scheme == "wss" ? 443 : 80)
          io = open_socket(uri, port, ssl_context)
          client = new(io, host: uri.host, path: uri.request_uri.then { |path| path.empty? ? "/" : path }, address: url).tap(&:handshake)
          io = nil # the client keeps it now
          client
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, OpenSSL::SSL::SSLError => e
          raise HandshakeFailed, connection_words(url, e)
        ensure
          io&.close # a handshake that failed, however it failed, leaves no socket open
        end

        def self.open_socket(uri, port, ssl_context)
          tcp = TCPSocket.new(uri.host, port)
          # A match sends a few bytes every pass: each goes out as it is written (see LineChannel).
          tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
          return tcp unless uri.scheme == "wss"

          context = ssl_context || OpenSSL::SSL::SSLContext.new.tap { |each| each.set_params }
          secure = OpenSSL::SSL::SSLSocket.new(tcp, context)
          secure.hostname = uri.host
          secure.sync_close = true
          secure.connect
          secure.post_connection_check(uri.host)
          secure
        rescue StandardError
          tcp&.close # a certificate that did not pass leaves no socket open
          raise
        end

        def self.connection_words(url, error)
          case error
          when Errno::ECONNREFUSED then "Nobody answers at the relay address #{url}. To fix this, check the address."
          when SocketError then "This computer cannot find the relay at #{url}. To fix this, check the address."
          when OpenSSL::SSL::SSLError then "The relay at #{url} did not pass the check of its certificate (#{error.message}). To fix this, check the address."
          else "This computer cannot reach the relay at #{url}. To fix this, check the address and the network."
          end
        end
        private_class_method :open_socket, :connection_words

        # A connection on +io+, already open to a server at +host+. Call #handshake before anything else.
        def initialize(io, host:, path: "/", address: nil, mask_key: -> { Framing.client_mask_key })
          @io = io
          @host = host
          @path = path
          @address = address || "#{host}#{path}"
          @mask_key = mask_key
          @reader = Reader.new
          @messages = []
          @pieces = nil # the text of a message that comes in several frames, so far
          @closing = false
          @ended = false
        end

        def handshake
          key = Handshake.new_key
          @io.write(Handshake.request(@host, @path, key))
          head, rest = Handshake.read_head(@io)
          Handshake.check_response!(head, key, @address)
          @reader.feed(rest)
          self
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          raise HandshakeFailed, "The relay at #{@address} closed the connection before it answered. To fix this, check the address."
        end

        def send_text(text)
          return if @ended || @closing

          write(Framing.encode(:text, text.b, mask_key: @mask_key.call))
        end

        # The next whole message that has arrived, or nil.
        def receive_text
          read_what_has_arrived
          @messages.shift
        end

        def pending?
          read_what_has_arrived
          !@messages.empty?
        end

        # True once the relay has gone and every message it sent has been read.
        def closed?
          read_what_has_arrived
          @ended && @messages.empty?
        end

        # Returns when there is a message to read, or the connection is closed.
        def wait_for_text
          IO.select([@io.respond_to?(:to_io) ? @io.to_io : @io]) until pending? || closed? || buffered_in_tls?
        end

        # Says goodbye and closes. The relay tells the others this machine has gone.
        def close
          unless @closing || @ended
            @closing = true
            write(Framing.encode(:close, Framing.close_payload(CLOSE_NORMAL), mask_key: @mask_key.call))
          end
          @ended = true
          SocketEnd.close(@io)
        end

        private

        # TLS holds bytes it has read and not given out, which a wait on the socket would not wake for.
        def buffered_in_tls? = @io.respond_to?(:pending) && @io.pending.to_i.positive?

        def write(bytes)
          @io.write(bytes)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, OpenSSL::SSL::SSLError
          @ended = true
        end

        # Everything the socket holds now, taken apart into frames and acted on. The end is noticed here, and a
        # relay that breaks the protocol (a frame or a message too big to keep, among others) ends the connection.
        def read_what_has_arrived
          return if @ended && @io.closed?

          gone = read_and_act
          act_on_frames
          @ended = true if gone
        rescue ProtocolError
          fail_connection
        end

        # Reads and acts on what has come, until there is nothing more for now. Gives back true when the other end
        # has gone. A ProtocolError is left to the caller.
        def read_and_act
          loop do
            @reader.feed(@io.read_nonblock(4096))
            act_on_frames
          end
        rescue IO::WaitReadable, OpenSSL::SSL::SSLErrorWaitReadable
          false
        rescue EOFError, Errno::ECONNRESET, IOError
          true
        end

        def act_on_frames
          while (frame = @reader.next_frame)
            act_on(frame)
          end
        end

        def act_on(frame)
          case frame.opcode
          when :text, :continuation then keep_text(frame)
          when :ping then write(Framing.encode(:pong, frame.payload, mask_key: @mask_key.call))
          when :close then answer_close(frame)
          end
        end

        def keep_text(frame)
          if frame.opcode == :text
            @pieces = frame.payload.dup
          else
            raise ProtocolError, "A message was continued that was not begun." unless @pieces

            Framing.refuse_message_too_big!(@pieces, frame.payload)
            @pieces << frame.payload
          end
          return unless frame.fin

          @messages << @pieces.force_encoding(Encoding::UTF_8)
          @pieces = nil
        end

        # The relay says it is closing: this answers in kind (once) and ends.
        def answer_close(frame)
          write(Framing.encode(:close, frame.payload.byteslice(0, 2).to_s, mask_key: @mask_key.call)) unless @closing
          @closing = true
          @ended = true
        end

        def fail_connection
          write(Framing.encode(:close, Framing.close_payload(CLOSE_PROTOCOL_ERROR), mask_key: @mask_key.call))
          @ended = true
          SocketEnd.close(@io)
        end
      end
    end
  end
end
