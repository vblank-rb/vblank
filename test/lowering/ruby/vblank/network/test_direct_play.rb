# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"

# JOINING AND HOSTING BY ADDRESS, where it goes wrong: whatever stops a machine joining or hosting leaves no
# socket of its own open. The other end here is a plain TCP server that says what the test wants it to.
class TestDirectPlay < Minitest::Test
  Network = VBlank::Network

  FUSE_SECONDS = 10

  PRINT = Network::Fingerprint.new(title: "WANDERERS", console: "gba", digest: "ab12cd34")

  Thread.report_on_exception = false

  # A host that answers the first line it is sent with +reply+, then tells whether the joining machine closed its
  # socket: true once it reads the end, false if nothing comes before the fuse.
  private def host_that_answers(server, reply)
    Thread.new do
      socket = server.accept
      socket.gets
      socket.write("#{reply}\n") if reply
      Timeout.timeout(FUSE_SECONDS) { socket.read } && true
    rescue Timeout::Error
      false
    ensure
      socket&.close
    end
  end

  private def address_of(server) = Network::DirectPlay::Address.new(host: "127.0.0.1", port: server.addr[1])

  def test_a_room_the_host_refuses_leaves_no_socket_open
    server = TCPServer.new("127.0.0.1", 0)
    closed = host_that_answers(server, '{"v":1,"type":"error","reason":"no_more_rooms","words":"No."}')

    assert_raises(Network::RoomRefused) { Network::DirectPlay.join(address_of(server), fingerprint: PRINT) }

    assert closed.value, "the joining machine closed its socket"
  ensure
    server&.close
  end
end
