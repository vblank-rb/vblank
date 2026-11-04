# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# TWO RUBY BUILDS SHARING A ROOM ON THE STAND-IN RELAY OVER A WEBSOCKET: the relay listens on a port of this
# computer (StandInRelayServer, in a thread), and each machine, in a thread of its own, connects to it with
# the WebSocket client, makes the room or joins it by its code, and plays. The machines wait on real sockets,
# and the match is the same match whichever thread is quicker, which is what lockstep is for.
class TestLockstepOverWebSocket < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 30
  WALKS = %i[right left up down].freeze

  Thread.report_on_exception = false

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  private def with_relay
    server = Network::StandInRelayServer.new(relay: Network::StandInRelay.new).start
    yield server
  ensure
    server&.stop
  end

  # One machine: connects, makes a room (when +code_box+ is empty) or joins the code in it, and plays.
  # +players+ is how many the match holds. Gives back its device and its lockstep.
  private def machine(url, code_box, index, players:, passes: PASSES, game: program)
    line = Network::WebSocket::Client.connect(url)
    print = Network::Fingerprint.of(game, title: "WANDERERS")
    lockstep = if index.zero?
                 transport = Network::RelayTransport.make_room(line)
                 (players - 1).times { code_box << transport.code } # one for each machine that joins
                 Network::Lockstep.host(transport: transport, fingerprint: print, players: players, seed: 5, input_delay: 2,
                                        checkpoint_every: 4)
               else
                 code = code_box.pop(timeout: 30) or raise "no room code"
                 Network::Lockstep.join(transport: Network::RelayTransport.join_room(line, code), fingerprint: print)
               end
    device = Headless.new(frames: passes, buttons: (2..passes).to_h { |pass| [pass, [WALKS.fetch(index)]] })
    Session.new(game, network: lockstep).play(device)
    [device, lockstep]
  end

  private def play(server, players, passes: [PASSES] * players)
    box = Queue.new
    threads = Array.new(players) do |index|
      Thread.new do
        machine(server.url, box, index, players: players, passes: passes[index])
      end
    end
    threads.map { |thread| begin; thread.value; rescue StandardError => e; e; end }
  end

  private def checks(device) = device.pictures.map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  def test_two_builds_share_a_room_on_the_relay_over_a_websocket_and_agree_on_every_pass
    with_relay do |server|
      results = play(server, 2)

      results.each { |result| refute_kind_of Exception, result }
      assert_equal PASSES, results.first.first.pictures.size
      assert_equal checks(results.first.first), checks(results.last.first)
    end
  end

  def test_four_builds_share_a_room
    with_relay do |server|
      results = play(server, 4)

      results.each { |result| refute_kind_of Exception, result }
      assert_equal 1, results.map { |device, _lockstep| checks(device) }.uniq.size
    end
  end

  def test_a_player_who_goes_is_seen_leaving_on_the_same_pass_by_the_others
    with_relay do |server|
      results = play(server, 3, passes: [PASSES, PASSES, 12])

      results.each { |result| refute_kind_of Exception, result }
      left = results.first(2).map { |_device, lockstep| lockstep.events.select { |event| event.kind == :left } }
      assert_equal left.first, left.last
      assert_equal [results.last.last.player], left.first.map(&:player)
    end
  end

  # A connection that never sends its handshake does not stop the relay answering the next one.
  def test_a_silent_connection_does_not_keep_the_relay_from_the_others
    with_relay do |server|
      silent = TCPSocket.new("127.0.0.1", server.port)
      half = TCPSocket.new("127.0.0.1", server.port)
      half.write("GET / HTTP/1.1\r\nHost: x\r\n")

      transport = Timeout.timeout(10) { Network::RelayTransport.make_room(Network::WebSocket::Client.connect(server.url)) }

      assert_equal 1, transport.id
    ensure
      silent&.close
      half&.close
    end
  end

  def test_a_wrong_code_is_said_in_plain_words
    with_relay do |server|
      line = Network::WebSocket::Client.connect(server.url)

      error = assert_raises(Network::RoomRefused) { Network::RelayTransport.join_room(line, "ZZZZ") }

      assert_equal :no_such_room, error.reason
      assert_match(/no room with the code ZZZZ/, error.message)
    end
  end
end
