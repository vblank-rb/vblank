# frozen_string_literal: true

require "test_helper"
require "node_copy"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# COPIES OF A GAME BUILT AS JAVASCRIPT MAKE AND JOIN A ROOM ON THE STAND-IN RELAY (rg_relay.js): they speak the
# relay's messages, get a code, give it to the others, and play, beside each other and beside a Ruby build of the
# game. A browser can only make a WebSocket connection, so this is how a page reaches a match. In these tests
# the line to the relay is carried by test/node_copy.rb, as the match's messages are in test_node_lockstep.rb.
class TestNodeRelay < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 30
  RIGHT = 1 << 4
  LEFT = 1 << 5

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  private def settings(players) = { seed: 5, input_delay: 2, checkpoint_every: 1, players: players }

  private def world
    relay = Network::StandInRelay.new
    [relay, Network::Scheduler.new(movement: -> { relay.pending? })]
  end

  private def line_for(relay, scheduler) = Network::InProcessLine.new(relay.connect, scheduler)

  private def node(relay, scheduler, box, hold, host: nil)
    NodeCopy.relay_copy(program, line: line_for(relay, scheduler), passes: PASSES, code_box: box, hold: hold, host: host)
  end

  # A Ruby build that makes or joins a room through the same relay.
  private def ruby_copy(relay, scheduler, box, walk, host: nil)
    line = line_for(relay, scheduler)
    print = Network::Fingerprint.of(program, title: "WANDERERS")
    lambda do
      if host
        transport = Network::RelayTransport.make_room(line)
        box.concat([transport.code] * 8)
        lockstep = Network::Lockstep.host(transport: transport, fingerprint: print, players: host[:players], seed: host[:seed],
                                          input_delay: host[:input_delay], checkpoint_every: host[:checkpoint_every])
      else
        lockstep = Network::Lockstep.join(transport: Network::RelayTransport.join_room(line, box.first), fingerprint: print)
      end
      device = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [walk]] })
      Session.new(program, network: lockstep).play(device)
      device
    end
  end

  private def pictures_of(device) = device.pictures.first(PASSES - 1).map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  def test_two_node_copies_make_and_join_a_room_and_agree_on_every_pass
    relay, scheduler = world
    box = []

    first, second = scheduler.play([node(relay, scheduler, box, RIGHT, host: settings(2)), node(relay, scheduler, box, LEFT)]).map(&:value)

    assert first.success, first.error
    assert second.success, second.error
    assert_match(/\A\w{4}\z/, first.room)
    assert_equal first.states, second.states
    assert_equal first.pictures, second.pictures
    assert_equal PASSES - 1, first.states.size
  end

  def test_a_wrong_code_is_said_in_plain_words
    relay, scheduler = world

    played = scheduler.play([node(relay, scheduler, %w[ZZZZ], LEFT)]).first.value

    refute played.success
    assert_match(/There is no room with the code ZZZZ/, played.error)
  end

  def test_a_node_copy_and_a_ruby_build_share_a_room_and_agree
    relay, scheduler = world
    box = []

    outcomes = scheduler.play([node(relay, scheduler, box, RIGHT, host: settings(2)), ruby_copy(relay, scheduler, box, :left)])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    node_side = outcomes.first.value
    assert node_side.success, node_side.error
    assert_equal pictures_of(outcomes.last.value), node_side.pictures
  end

  def test_a_ruby_build_makes_the_room_and_a_node_copy_joins_it
    relay, scheduler = world
    box = []

    outcomes = scheduler.play([ruby_copy(relay, scheduler, box, :right, host: settings(2)), node(relay, scheduler, box, LEFT)])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    assert outcomes.last.value.success, outcomes.last.value.error
    assert_equal pictures_of(outcomes.first.value), outcomes.last.value.pictures
  end

  def test_a_relay_of_an_older_format_is_said_so_in_plain_words
    relay = Network::StandInRelay.new
    relay.define_singleton_method(:receive) do |connection, _text|
      connection.deliver(JSON.generate({ "v" => 1, "type" => "error", "reason" => "version", "supported" => [0] }))
    end
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })

    played = scheduler.play([node(relay, scheduler, [], RIGHT, host: settings(2))]).first.value

    refute played.success
    assert_match(/The relay knows version 0 of the network format, and this game speaks version 1/, played.error)
    assert_match(/use a newer relay/, played.error)
  end

  def test_a_game_of_another_console_is_refused_through_the_relay_in_plain_words
    relay, scheduler = world
    box = []
    other = Wanderers::GAME.checked_program(err: nil, console: :gbc, settings: { you_line: false })
    refused = NodeCopy.relay_copy(other, line: line_for(relay, scheduler), passes: PASSES, code_box: box, hold: LEFT)

    host, intruder, friend = scheduler.play([node(relay, scheduler, box, RIGHT, host: settings(2)), refused, node(relay, scheduler, box, LEFT)]).map(&:value)

    assert host.success, host.error
    assert friend.success, friend.error
    refute intruder.success
    assert_match(/This match is for the Game Boy Advance, and your game is built for the Game Boy Color/, intruder.error)
  end
end
