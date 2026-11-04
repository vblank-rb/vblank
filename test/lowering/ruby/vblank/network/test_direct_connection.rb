# frozen_string_literal: true

require "test_helper"
require "socket"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# MACHINES THAT CONNECT TO EACH OTHER DIRECTLY: one hosts (it is the room, and player 1) and the others
# connect to it over a socket, in a test a UNIXSocket pair, and once a TCP port on this machine. Each machine
# runs in a thread of its own because each really waits on its socket; the match is the same match whatever
# order the threads happen to run in, which is what lockstep is for. The pieces are a LineChannel (a line of
# text a message over a socket) and a DirectRoom (the host's relay).
class TestDirectConnection < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 30
  WALKS = %i[right left up down].freeze

  # Each thread reports its own failure through #value, and no failure prints a trace as well.
  Thread.report_on_exception = false

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  private def print(game = program) = Network::Fingerprint.of(game, title: "WANDERERS")

  private def device_for(player, passes: PASSES)
    Headless.new(frames: passes, buttons: (2..passes).to_h { |pass| [pass, [WALKS.fetch(player - 1)]] })
  end

  # The host plays in the calling thread's own, started with a block; a client plays in one of its own.
  # Each gives back its device and its lockstep.
  private def host_machine(room, players:, passes: PASSES)
    transport = Network::RelayTransport.make_room(room.host_line)
    lockstep = Network::Lockstep.host(transport: transport, fingerprint: print, players: players, seed: 9, input_delay: 2,
                                      checkpoint_every: 4)
    machine(lockstep, 1, passes)
  end

  private def client_machine(socket, player, passes: PASSES, game: program)
    transport = Network::RelayTransport.join_room(Network::LineChannel.new(socket), Network::DirectRoom::CODE)
    lockstep = Network::Lockstep.join(transport: transport, fingerprint: print(game))
    machine(lockstep, player, passes, game: game)
  end

  private def machine(lockstep, player, passes, game: program)
    device = device_for(player, passes: passes)
    Session.new(game, network: lockstep).play(device)
    [device, lockstep]
  end

  private def checks(device) = device.pictures.map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  # Plays a match of +clients+ other machines on UNIX sockets beside the host. Gives each machine's result:
  # [device, lockstep], or the error that ended it.
  private def play_over_unix_sockets(clients, host_passes: PASSES, client_passes: [PASSES] * clients)
    room = Network::DirectRoom.new
    sockets = Array.new(clients) { UNIXSocket.pair }
    sockets.each { |ours, _theirs| room.add_client(ours) }
    threads = sockets.each_with_index.map do |(_ours, theirs), index|
      Thread.new { client_machine(theirs, index + 2, passes: client_passes[index]) }
    end
    host = begin
      host_machine(room, players: clients + 1, passes: host_passes)
    rescue StandardError => e
      e
    end
    [host, *threads.map { |thread| begin; thread.value; rescue StandardError => e; e; end }]
  end

  def test_two_machines_over_a_socket_pair_agree_on_every_pass
    results = play_over_unix_sockets(1)

    results.each { |result| refute_kind_of Exception, result }
    assert_equal PASSES, results.first.first.pictures.size
    assert_equal checks(results.first.first), checks(results.last.first)
  end

  def test_four_machines_agree_on_every_pass
    results = play_over_unix_sockets(3)

    results.each { |result| refute_kind_of Exception, result }
    assert_equal 1, results.map { |device, _lockstep| checks(device) }.uniq.size
  end

  def test_a_player_who_goes_is_a_player_who_left_on_the_same_pass_everywhere_and_nothing_hangs
    results = play_over_unix_sockets(2, client_passes: [PASSES, 12])

    results.each { |result| refute_kind_of Exception, result }
    left = [results[0], results[1]].map { |_device, lockstep| lockstep.events.select { |event| event.kind == :left } }
    assert_equal 1, left.first.size
    assert_equal left.first, left.last
    assert_equal 3, left.first.first.player
    assert_equal checks(results[0].first), checks(results[1].first)
    assert_equal PASSES, results[0].first.pictures.size
  end

  def test_a_machine_that_plays_another_game_is_refused_over_the_socket
    other = VBlank.game("OTHER", consoles: %i[gba], players: 4) { game_loop { pixel 2, 2, :red } }.checked_program(err: nil, console: :gba)
    room = Network::DirectRoom.new
    ours, theirs = UNIXSocket.pair
    room.add_client(ours)
    intruder = Thread.new { client_machine(theirs, 2, game: other) }
    friend_ours, friend_theirs = UNIXSocket.pair
    room.add_client(friend_ours)
    friend = Thread.new { client_machine(friend_theirs, 3) }

    host = host_machine(room, players: 2)

    assert_equal PASSES, host.first.pictures.size
    assert_kind_of Network::Refused, assert_raises(Network::Refused) { intruder.value }
    refute_kind_of Exception, friend.value
  end

  def test_two_machines_over_a_tcp_port_on_this_machine_agree_on_every_pass
    server = TCPServer.new("127.0.0.1", 0)
    room = Network::DirectRoom.new(listener: server)
    client = Thread.new { client_machine(TCPSocket.new("127.0.0.1", server.addr[1]), 2) }

    host_device, = host_machine(room, players: 2)
    client_device, = client.value

    assert_equal checks(host_device), checks(client_device)
  ensure
    server&.close
  end

  def test_a_line_of_text_arrives_whole_whatever_pieces_it_comes_in
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    ours.write("first\nsec")

    assert_equal "first", channel.receive_text
    assert_nil channel.receive_text
    ours.write("ond\nthird\n")
    channel.wait_for_text

    assert_equal %w[second third], [channel.receive_text, channel.receive_text]
  end

  def test_what_a_machine_sent_before_it_went_is_read_before_the_line_is_closed
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    ours.write("last words\n")
    ours.close

    refute channel.closed?, "a line is still to be read"
    assert_equal "last words", channel.receive_text
    assert channel.closed?
  end

  def test_writing_to_a_machine_that_has_gone_does_not_raise
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    ours.close

    channel.send_text("anyone there?")

    assert channel.closed?
  end
end
