# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"
require "zlib"
require "vblank/live"
ShareableConstants.require_file(VBlank.root.join("examples/wanderers").to_s)

# Machines that connect to each other directly: one hosts (it is the room, and player 1) and the others
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

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_mark: false })

  private def fingerprint_of(game = program) = Network::Fingerprint.of(game, title: "WANDERERS")

  private def device_for(player, passes: PASSES)
    Headless.new(frames: passes, buttons: (2..passes).to_h { |pass| [pass, [WALKS.fetch(player - 1)]] })
  end

  # The host plays in the calling thread's own, started with a block; a client plays in one of its own.
  # Each gives back its device and its lockstep.
  private def host_machine(room, players:, passes: PASSES)
    transport = Network::RelayTransport.make_room(room.host_line)
    lockstep = Network::Lockstep.host(transport: transport, fingerprint: fingerprint_of, players: players, seed: 9, input_delay: 2,
                                      checkpoint_every: 1) # the machines compare their states on every pass
    machine(lockstep, 1, passes)
  end

  private def client_machine(socket, player, passes: PASSES, game: program, line_timing: {})
    client_on_line(Network::LineChannel.new(socket, **line_timing), player, passes: passes, game: game)
  end

  private def client_on_line(line, player, passes: PASSES, game: program)
    transport = Network::RelayTransport.join_room(line, Network::DirectRoom::CODE)
    lockstep = Network::Lockstep.join(transport: transport, fingerprint: fingerprint_of(game))
    machine(lockstep, player, passes, game: game)
  end

  private def machine(lockstep, player, passes, game: program)
    device = device_for(player, passes: passes)
    Session.new(game, network: lockstep).play(device)
    [device, lockstep]
  end

  private def checks(device) = device.pictures.map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  # Plays a match of +clients+ other machines on UNIX sockets beside the host. Gives each machine's result:
  # [device, lockstep], or the error that ended it. The clients numbered in +vanishing+ (0 the first) go
  # without a word when their passes are done: their socket stays open and nothing more comes on it, as
  # when a cable is pulled. +line_timing+ is every line's, the room's and the clients'.
  private def play_over_unix_sockets(clients, host_passes: PASSES, client_passes: [PASSES] * clients, vanishing: [], line_timing: {})
    room = Network::DirectRoom.new(**line_timing)
    sockets = Array.new(clients) { UNIXSocket.pair }
    sockets.each { |ours, _theirs| room.add_client(ours) }
    threads = sockets.each_with_index.map do |(_ours, theirs), index|
      theirs = Vanishes.new(theirs) if vanishing.include?(index)
      Thread.new { client_machine(theirs, index + 2, passes: client_passes[index], line_timing: line_timing) }
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
    # The room numbers the machines in the order they ask to join, which the threads race for.
    assert_equal results[2].last.player, left.first.first.player
    assert_equal checks(results[0].first), checks(results[1].first)
    assert_equal PASSES, results[0].first.pictures.size
  end

  # A socket whose machine goes without a word: closing it does nothing, so its other end hears no end
  # and no more lines, as when a cable is pulled or the machine freezes.
  class Vanishes
    def initialize(socket) = @socket = socket
    def to_io = @socket
    def read_nonblock(...) = @socket.read_nonblock(...)
    def write_nonblock(...) = @socket.write_nonblock(...)
    def closed? = false
    def close = nil
  end

  # Short times, so a machine that goes silent is found in a test's time: still several beats to the
  # silence, so a busy computer does not take a machine that is there for one that went.
  QUICK_LINES = { silent_seconds: 2, beat_seconds: 0.1 }.freeze

  # Longest a match with a silent machine in it may take. It only catches a hang.
  HANG_SECONDS = 60

  def test_a_machine_that_goes_silent_is_a_player_who_left_on_the_same_pass_everywhere
    results = Timeout.timeout(HANG_SECONDS) do
      play_over_unix_sockets(2, client_passes: [PASSES, 12], vanishing: [1], line_timing: QUICK_LINES)
    end

    results.each { |result| refute_kind_of Exception, result }
    left = [results[0], results[1]].map { |_device, lockstep| lockstep.events.select { |event| event.kind == :left } }
    assert_equal 1, left.first.size, "the host saw the silent machine leave"
    assert_equal left.first, left.last
    assert_equal results[2].last.player, left.first.first.player
    assert_equal checks(results[0].first), checks(results[1].first)
    assert_equal PASSES, results[0].first.pictures.size
  end

  # A machine waiting for the host to start sends no message, and one connected but slow to ask to join
  # sends none either, but each says it is there all the same.
  def test_a_machine_that_waits_longer_than_the_silence_to_begin_is_still_in_the_match
    room = Network::DirectRoom.new(**QUICK_LINES)
    early_ours, early_theirs = UNIXSocket.pair
    late_ours, late_theirs = UNIXSocket.pair
    room.add_client(early_ours)
    room.add_client(late_ours)
    late_line = Network::LineChannel.new(late_theirs, **QUICK_LINES)
    early = Thread.new { client_machine(early_theirs, 2, line_timing: QUICK_LINES) }
    late = Thread.new do
      sleep QUICK_LINES[:silent_seconds] * 2
      client_on_line(late_line, 3)
    end

    host = Timeout.timeout(HANG_SECONDS) { host_machine(room, players: 3) }

    assert_empty host.last.events
    assert_equal checks(host.first), checks(early.value.first)
    assert_equal checks(host.first), checks(late.value.first)
  end

  def test_a_line_that_hears_nothing_for_its_silent_time_is_closed
    _ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs, silent_seconds: 0.3, beat_seconds: 0.1)

    assert Timeout.timeout(HANG_SECONDS) { channel.wait_for_text }, "the wait ends when the silence does"
    assert_predicate channel, :closed?
  end

  # A line closed for silence lets its socket go: nothing more can come on it.
  def test_a_line_closed_for_silence_closes_its_socket
    _ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs, silent_seconds: 0.3, beat_seconds: 0.1)
    Timeout.timeout(HANG_SECONDS) { channel.wait_for_text }

    assert_predicate theirs, :closed?
  end

  # What a line was sent last, its peer's leaving above all, reaches the peer when the line closes,
  # though the socket would not take it all at once: the close waits for it, a little while.
  def test_what_the_socket_would_not_take_yet_is_sent_before_the_line_closes
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs, beat_seconds: 60)
    lines = Array.new(2000) { |index| "line #{index} #{'x' * 100}" }
    reader = Thread.new { ours.read }
    lines.each { |line| channel.send_text(line) }
    channel.close

    assert_equal lines, Timeout.timeout(HANG_SECONDS) { reader.value }.split("\n")
  end

  # Closing stops the beat before the last lines go, so no line is sent twice, however the two meet.
  def test_a_line_closed_while_it_beats_sends_each_line_once
    20.times do
      ours, theirs = UNIXSocket.pair
      channel = Network::LineChannel.new(theirs, beat_seconds: 0.001)
      reader = Thread.new { ours.read }
      sleep 0.005
      channel.send_text("last")
      channel.close

      assert_equal 1, Timeout.timeout(HANG_SECONDS) { reader.value }.split("\n").count("last")
    end
  end

  def test_two_lines_with_nothing_to_say_keep_each_other_open
    ours, theirs = UNIXSocket.pair
    one = Network::LineChannel.new(ours, silent_seconds: 0.5, beat_seconds: 0.05)
    other = Network::LineChannel.new(theirs, silent_seconds: 0.5, beat_seconds: 0.05)

    refute other.wait_for_text(1.5), "an empty line is no message"
    refute_predicate one, :closed?
    refute_predicate other, :closed?
  end

  # The host is the room: with it gone the two others cannot reach each other, nor agree which of its
  # passes was its last, so each stops, saying why.
  def test_when_the_host_goes_in_a_match_of_three_the_others_stop_saying_why
    results = Timeout.timeout(HANG_SECONDS) { play_over_unix_sockets(2, host_passes: 12) }

    refute_kind_of Exception, results[0]
    results.drop(1).each do |result|
      assert_kind_of Network::MatchCutOff, result
      assert_match(/cannot reach the other players/, result.message)
    end
  end

  # With one other machine, nobody is left to disagree with: the host left, and the game goes on.
  def test_when_the_host_goes_in_a_match_of_two_the_other_plays_on
    results = Timeout.timeout(HANG_SECONDS) { play_over_unix_sockets(1, host_passes: 12) }

    results.each { |result| refute_kind_of Exception, result }
    assert_equal [1], results[1].last.events.select { |event| event.kind == :left }.map(&:player)
    assert_equal PASSES, results[1].first.pictures.size
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

  # A line a pass is a few bytes, and TCP left to itself holds a small write back to send with the
  # next: a TCP line sends each line as it is written.
  def test_a_tcp_line_sends_each_line_as_it_is_written
    server = TCPServer.new("127.0.0.1", 0)
    socket = TCPSocket.new("127.0.0.1", server.addr[1])
    Network::LineChannel.new(socket)

    assert socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
  ensure
    socket&.close
    server&.close
  end

  def test_a_machine_that_asks_a_direct_host_for_a_room_of_its_own_is_told_no_and_the_room_goes_on
    room = Network::DirectRoom.new
    Network::RelayTransport.make_room(room.host_line)
    ours, theirs = UNIXSocket.pair
    room.add_client(ours)
    stranger = Network::LineChannel.new(theirs)
    stranger.send_text('{"v":1,"type":"make_room"}')
    room.pump
    stranger.wait_for_text(5)

    assert_equal "no_more_rooms", JSON.parse(stranger.receive_text).fetch("reason")
    stranger.send_text(%({"v":1,"type":"join_room","code":"#{Network::DirectRoom::CODE}"}))
    room.pump
    stranger.wait_for_text(5)
    assert_equal "room_joined", JSON.parse(stranger.receive_text).fetch("type")
  end

  def test_a_machine_cannot_say_that_it_or_another_has_left
    room = Network::DirectRoom.new
    host = Network::RelayTransport.make_room(room.host_line)
    ours, theirs = UNIXSocket.pair
    room.add_client(ours)
    guest = Network::LineChannel.new(theirs)
    guest.send_text(%({"v":1,"type":"join_room","code":"#{Network::DirectRoom::CODE}"}))
    guest.send_text('{"v":1,"type":"left"}')
    room.pump
    guest.wait_for_text(5)
    guest.receive_text

    assert_nil host.receive_message
    guest.wait_for_text(5)
    assert_equal "bad_message", JSON.parse(guest.receive_text).fetch("reason")
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

  # A socket whose first read finds nothing, and whose other end sends +bytes+ just after that read: the
  # line arrives between one look at the socket and the next, every time.
  class ArrivesAfterFirstRead
    def initialize(socket, other_end, bytes)
      @socket = socket
      @other_end = other_end
      @bytes = bytes
    end

    def to_io = @socket

    def read_nonblock(...)
      return @socket.read_nonblock(...) unless @bytes

      @other_end.write(@bytes)
      @bytes = nil
      raise IO::EAGAINWaitReadable
    end

    def write_nonblock(...) = @socket.write_nonblock(...)
    def closed? = @socket.closed?
    def close = @socket.close
  end

  # The wait once read the socket a second time while deciding whether to sleep, kept the line it found,
  # and then slept on a socket with nothing left in it.
  def test_a_line_that_arrives_while_the_wait_looks_still_ends_the_wait
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(ArrivesAfterFirstRead.new(theirs, ours, "a line\n"))

    assert channel.wait_for_text(2), "the wait slept through a line it had already read"
    assert_equal "a line", channel.receive_text
  end

  # The clock is held from below alone: a busy computer can only make the wait longer, never cut it
  # short, so load cannot fail this.
  def test_a_wait_with_a_time_limit_waits_that_long_when_nothing_comes
    _ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    channel.wait_for_text(0.2)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.19
  end

  # The limit only catches a wait that never ends: the line comes long before it.
  def test_a_wait_with_a_time_limit_ends_when_a_line_comes
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    ours.write("half a li")
    Thread.new { sleep 0.05; ours.write("ne\n") }

    channel.wait_for_text(30)

    assert_equal "half a line", channel.receive_text
  end

  def test_a_line_longer_than_the_most_it_keeps_closes_the_channel_after_the_lines_before_it
    ours, theirs = UNIXSocket.pair
    channel = Network::LineChannel.new(theirs)
    writer = Thread.new do
      ours.write("whole\n")
      ours.write("x" * (Network::LineChannel::MOST_LINE_BYTES * 2))
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    Timeout.timeout(30) do
      until theirs.closed?
        channel.pending? # reads what has come
        IO.select([theirs], nil, nil, 0.05) unless theirs.closed?
      end
    end
    writer.join

    assert_equal "whole", channel.receive_text
    assert_predicate channel, :closed?
    assert_predicate channel.io, :closed?
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
