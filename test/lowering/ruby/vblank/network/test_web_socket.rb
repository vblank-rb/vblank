# frozen_string_literal: true

require "test_helper"
require "socket"
require "openssl"
require "timeout"

# THE WEBSOCKET CLIENT IN PURE RUBY: the frames as bytes (with the examples the standard itself gives), the
# opening handshake, ping, close, and a message that arrives in pieces. The connection is a UNIXSocket pair in
# these, with the other end played by WebSocket::ServerPeer in a thread, so no port and no clock is used. The
# one test that uses TLS makes a certificate for itself and trusts only that.
class TestWebSocket < Minitest::Test
  WebSocket = VBlank::Network::WebSocket
  Framing = WebSocket::Framing

  # The longest a test waits for the other end before it gives up: a fuse, not part of any test.
  FUSE_SECONDS = 30

  # A frame is sent unmasked by a server and masked with four bytes by a client.
  MASKS = [nil, "abcd"].freeze

  # --- the bytes ---

  def test_a_client_frame_is_the_example_the_standard_gives
    bytes = Framing.encode(:text, "Hello", mask_key: [0x37, 0xfa, 0x21, 0x3d].pack("C*"))

    assert_equal [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58], bytes.bytes
  end

  def test_a_server_frame_is_the_example_the_standard_gives
    assert_equal [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f], Framing.encode(:text, "Hello").bytes
  end

  def test_a_frame_comes_back_whatever_its_length_and_whether_or_not_it_is_masked
    [0, 5, 125, 126, 300, 65_535, 65_536, 70_000].each do |length|
      MASKS.each do |key|
        payload = ("x" * length).b
        reader = WebSocket::Reader.new
        reader.feed(Framing.encode(:binary, payload, mask_key: key))

        frame = reader.next_frame

        assert_equal [true, :binary, payload], [frame.fin, frame.opcode, frame.payload], "#{length} bytes, mask #{key.inspect}"
        assert_nil reader.next_frame
      end
    end
  end

  def test_a_frame_that_arrives_a_byte_at_a_time_is_one_frame_at_the_end
    reader = WebSocket::Reader.new
    bytes = Framing.encode(:text, "in pieces", mask_key: "wxyz")

    bytes.bytes.first(bytes.bytesize - 1).each do |byte|
      reader.feed([byte].pack("C"))
      assert_nil reader.next_frame
    end
    reader.feed(bytes.byteslice(-1, 1))

    assert_equal "in pieces", reader.next_frame.payload
  end

  def test_a_message_bigger_than_the_most_it_reads_is_refused
    reader = WebSocket::Reader.new
    reader.feed([0x81, 127, WebSocket::MOST_PAYLOAD_BYTES + 1].pack("CCQ>").then { |bytes| bytes[0, 2] + [WebSocket::MOST_PAYLOAD_BYTES + 1].pack("Q>") })

    assert_raises(WebSocket::ProtocolError) { reader.next_frame }
  end

  def test_bits_this_does_not_know_are_a_protocol_error
    reader = WebSocket::Reader.new
    reader.feed([0xC1, 0x00].pack("CC"))

    assert_raises(WebSocket::ProtocolError) { reader.next_frame }
  end

  def test_the_answer_to_the_key_in_the_standard_is_the_one_it_gives
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WebSocket::Handshake.accept_for("dGhlIHNhbXBsZSBub25jZQ==")
  end

  # --- a connection ---

  # A client and the server's end of it: the server runs +serving+ in a thread, handed the peer.
  private def connected(&serving)
    ours, theirs = UNIXSocket.pair
    server = Thread.new do
      peer = WebSocket::ServerPeer.accept(theirs)
      serving&.call(peer)
      peer
    end
    client = WebSocket::Client.new(ours, host: "relay.test", path: "/room", address: "ws://relay.test/room").handshake
    [client, server]
  end

  private def wait_for_message(client) = Timeout.timeout(FUSE_SECONDS) { client.wait_for_text }

  def test_a_client_and_a_server_pass_text_both_ways
    client, server = connected do |peer|
      IO.select([peer.io])
      peer.read_messages.each { |text| peer.send_text("echo #{text}") }
    end
    client.send_text("hello relay")
    wait_for_message(client)

    assert_equal "echo hello relay", client.receive_text
    assert_equal "/room", server.value.path
  end

  def test_a_ping_is_answered_with_a_pong_carrying_the_same_bytes
    ours, theirs = UNIXSocket.pair
    server = Thread.new { WebSocket::ServerPeer.accept(theirs) }
    client = WebSocket::Client.new(ours, host: "relay.test").handshake
    peer = server.value
    peer.ping("are you there")
    reader = WebSocket::Reader.new

    Timeout.timeout(FUSE_SECONDS) do
      until (frame = reader.next_frame)
        client.pending? # reads the ping, and answers it
        IO.select([theirs], nil, nil, 0.05)
        reader.feed(theirs.read_nonblock(4096)) if IO.select([theirs], nil, nil, 0)
      end
      assert_equal [:pong, "are you there".b, true], [frame.opcode, frame.payload, frame.fin]
    end
  end

  def test_a_message_sent_in_pieces_is_one_message
    client, = connected do |peer|
      peer.io.write(Framing.encode(:text, "in ", fin: false))
      peer.io.write(Framing.encode(:ping, "x"))
      peer.io.write(Framing.encode(:continuation, "three ", fin: false))
      peer.io.write(Framing.encode(:continuation, "pieces"))
    end
    wait_for_message(client)

    assert_equal "in three pieces", client.receive_text
    assert_nil client.receive_text
  end

  # Each piece is small enough, and together they are more than a message may be: the connection is closed rather
  # than the memory filled.
  def test_a_message_sent_in_pieces_bigger_than_the_most_it_reads_closes_the_client
    piece = "x" * ((WebSocket::MOST_PAYLOAD_BYTES / 2) + 1)
    client, = connected do |peer|
      peer.io.write(Framing.encode(:text, piece, fin: false))
      peer.io.write(Framing.encode(:continuation, piece, fin: false))
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil # the client closed as it should
    end

    Timeout.timeout(FUSE_SECONDS) { sleep 0.01 until client.closed? }

    assert_predicate client, :closed?
    assert_nil client.receive_text
  end

  def test_a_message_sent_in_pieces_bigger_than_the_most_it_reads_closes_the_server_peer
    ours, theirs = UNIXSocket.pair
    server = Thread.new { WebSocket::ServerPeer.accept(theirs) }
    WebSocket::Client.new(ours, host: "relay.test").handshake
    peer = server.value
    piece = "x" * ((WebSocket::MOST_PAYLOAD_BYTES / 2) + 1)
    writer = Thread.new do
      [[:text, false], [:continuation, false]].each { |kind, fin| ours.write(Framing.encode(kind, piece, mask_key: "abcd", fin: fin)) }
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    Timeout.timeout(FUSE_SECONDS) do
      until peer.ended?
        IO.select([peer.io], nil, nil, 0.05)
        peer.read_messages
      end
    end
    writer.join

    assert_predicate peer.io, :closed?
  end

  def test_a_close_from_the_server_ends_the_connection_after_the_messages_before_it
    client, = connected do |peer|
      peer.send_text("last words")
      peer.close
    end
    Timeout.timeout(FUSE_SECONDS) { sleep 0.01 until client.pending? }

    refute client.closed?, "a message is still to be read"
    assert_equal "last words", client.receive_text
    # The close comes after the message, and may not have come yet.
    Timeout.timeout(FUSE_SECONDS) { sleep 0.01 until client.closed? }
  end

  def test_closing_tells_the_server_and_sends_nothing_more
    client, server = connected do |peer|
      IO.select([peer.io])
      peer.read_messages
    end
    client.close
    peer = server.value
    Timeout.timeout(FUSE_SECONDS) { sleep 0.01 until peer.ended? || peer.read_messages && peer.ended? }

    assert_predicate peer, :ended?
    assert_predicate client, :closed?
    client.send_text("too late") # does nothing and does not raise
  end

  def test_what_a_client_sends_is_masked
    ours, theirs = UNIXSocket.pair
    client = Thread.new { WebSocket::Client.new(ours, host: "relay.test").handshake }
    WebSocket::ServerPeer.accept(theirs)
    client = client.value
    client.send_text("secret")

    raw = Timeout.timeout(FUSE_SECONDS) { theirs.readpartial(64) }

    assert_equal 0x80, raw.getbyte(1) & 0x80, "the mask bit is set"
    refute_includes raw, "secret"
  end

  def test_a_server_that_does_not_agree_is_said_in_plain_words
    ours, theirs = UNIXSocket.pair
    Thread.new do
      theirs.readpartial(1024)
      theirs.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    end

    error = assert_raises(WebSocket::HandshakeFailed) { WebSocket::Client.new(ours, host: "relay.test", address: "ws://relay.test/x").handshake }

    assert_match(/did not accept a WebSocket connection \(it said HTTP 404\)/, error.message)
    assert_match(/check the relay address/, error.message)
  end

  def test_a_server_that_answers_with_the_wrong_proof_is_refused
    ours, theirs = UNIXSocket.pair
    Thread.new do
      theirs.readpartial(1024)
      theirs.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n")
    end

    error = assert_raises(WebSocket::HandshakeFailed) { WebSocket::Client.new(ours, host: "relay.test").handshake }

    assert_match(/not as a WebSocket does/, error.message)
  end

  def test_a_handshake_that_fails_leaves_no_socket_open
    server = TCPServer.new("127.0.0.1", 0)
    closed = Thread.new do
      socket = server.accept
      socket.readpartial(1024)
      socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
      Timeout.timeout(FUSE_SECONDS) { socket.read } && true
    rescue Timeout::Error
      false
    ensure
      socket&.close
    end

    assert_raises(WebSocket::HandshakeFailed) { WebSocket::Client.connect("ws://127.0.0.1:#{server.addr[1]}/") }

    assert closed.value, "the client closed its socket"
  ensure
    server&.close
  end

  def test_an_address_that_is_not_a_relay_address_is_said_in_plain_words
    ["http://relay.test/", "relay.test", ""].each do |url|
      error = assert_raises(WebSocket::HandshakeFailed, url.inspect) { WebSocket::Client.connect(url) }

      assert_match(/starts with ws:\/\/ or wss:\/\//, error.message)
    end
  end

  def test_nobody_at_the_address_is_said_in_plain_words
    unused = TCPServer.new("127.0.0.1", 0)
    port = unused.addr[1]
    unused.close

    error = assert_raises(WebSocket::HandshakeFailed) { WebSocket::Client.connect("ws://127.0.0.1:#{port}/") }

    assert_match(/Nobody answers at the relay address/, error.message)
  end

  # --- TLS ---

  def test_a_wss_address_is_reached_over_tls_and_the_relays_certificate_is_checked
    certificate, key = self_signed_certificate("relay.test")
    server_context = OpenSSL::SSL::SSLContext.new
    server_context.cert = certificate
    server_context.key = key
    listener = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), server_context)
    port = listener.to_io.addr[1]
    server = Thread.new do
      peer = WebSocket::ServerPeer.accept(listener.accept)
      IO.select([peer.io])
      peer.read_messages.each { |text| peer.send_text("secure #{text}") }
      peer
    end
    trusting = OpenSSL::SSL::SSLContext.new
    trusting.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(certificate) }
    trusting.verify_mode = OpenSSL::SSL::VERIFY_PEER

    client = WebSocket::Client.connect("wss://localhost:#{port}/", ssl_context: trusting)
    client.send_text("hello")
    wait_for_message(client)

    assert_equal "secure hello", client.receive_text
    server.join
  ensure
    listener&.close
  end

  def test_a_wss_address_whose_certificate_is_not_trusted_is_refused_in_plain_words
    certificate, key = self_signed_certificate("relay.test")
    server_context = OpenSSL::SSL::SSLContext.new
    server_context.cert = certificate
    server_context.key = key
    listener = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), server_context)
    port = listener.to_io.addr[1]
    Thread.new { listener.accept rescue nil }

    error = assert_raises(WebSocket::HandshakeFailed) { WebSocket::Client.connect("wss://localhost:#{port}/") }

    assert_match(/did not pass the check of its certificate/, error.message)
  ensure
    listener&.close
  end

  private def self_signed_certificate(name)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    certificate.public_key = key.public_key
    certificate.not_before = Time.at(0)
    certificate.not_after = Time.at(4_102_444_800)
    extensions = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
    certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost,DNS:#{name}"))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    [certificate, key]
  end
end
