# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# TWO RUBY COPIES OF A GAME PLAYING ONE MATCH THROUGH THE STAND-IN RELAY: one makes a room and gets a
# code, the other joins with it, and they play the match of test_lockstep.rb, speaking the network
# format (Network::Wire) to a relay that never reads the buttons. The relay is called in this process,
# and the copies take turns (Network::Scheduler), so the run is the same every time.
class TestLockstepOverRelay < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 30

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  # One copy: it makes the room (the first) or joins the code the first one wrote down.
  private def copy(relay, scheduler, room_code, walks:, game: program, title: "WANDERERS")
    line = Network::InProcessLine.new(relay.connect, scheduler)
    fingerprint = Network::Fingerprint.of(game, title: title)
    lambda do
      if room_code.empty?
        transport = Network::RelayTransport.make_room(line)
        room_code << transport.code
        lockstep = Network::Lockstep.host(transport: transport, fingerprint: fingerprint, players: 2, seed: 11, input_delay: 2)
      else
        transport = Network::RelayTransport.join_room(line, room_code.first)
        lockstep = Network::Lockstep.join(transport: transport, fingerprint: fingerprint)
      end
      device = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [walks]] })
      Session.new(game, network: lockstep).play(device)
      device
    end
  end

  private def play(relay, scheduler, copies) = scheduler.play(copies)

  private def checks(device) = device.pictures.map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  def test_two_copies_make_and_join_a_room_and_agree_on_every_pass
    relay = Network::StandInRelay.new
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })
    code = []

    outcomes = play(relay, scheduler, [copy(relay, scheduler, code, walks: :right), copy(relay, scheduler, code, walks: :left)])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    first, second = outcomes.map(&:value)
    assert_equal PASSES, first.pictures.size
    assert_equal checks(first), checks(second)
    assert_equal 4, code.first.size
  end

  def test_a_copy_that_joins_a_room_with_a_wrong_code_is_told_in_plain_words
    relay = Network::StandInRelay.new
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })

    outcomes = play(relay, scheduler, [copy(relay, scheduler, ["NOPE"], walks: :left)])

    assert_kind_of Network::RoomRefused, outcomes.first.error
    assert_equal :no_such_room, outcomes.first.error.reason
    assert_match(/no room with the code NOPE/, outcomes.first.error.message)
  end

  def test_a_game_of_another_console_is_refused_over_the_relay_too
    relay = Network::StandInRelay.new
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })
    code = []
    other = Wanderers::GAME.checked_program(err: nil, console: :gbc, settings: { you_line: false })

    outcomes = play(relay, scheduler, [copy(relay, scheduler, code, walks: :right), copy(relay, scheduler, code, walks: :left, game: other),
                                       copy(relay, scheduler, code, walks: :left)])

    assert_kind_of Network::Refused, outcomes[1].error
    assert_nil outcomes[0].error
    assert_nil outcomes[2].error
  end

  def test_a_relay_that_knows_only_an_older_format_is_said_so_in_plain_words
    relay = Network::StandInRelay.new
    relay.define_singleton_method(:receive) do |connection, text|
      connection.deliver(JSON.generate({ "v" => 1, "type" => "error", "reason" => "version", "supported" => [0] }))
    end
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })

    outcomes = play(relay, scheduler, [copy(relay, scheduler, [], walks: :right)])

    assert_kind_of Network::VersionMismatch, outcomes.first.error
    assert_match(/relay/, outcomes.first.error.message)
  end
end
