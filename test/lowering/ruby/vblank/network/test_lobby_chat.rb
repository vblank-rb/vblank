# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# CHAT BETWEEN THE PLAYERS OF A ROOM, BEFORE THE MATCH AND DURING IT, through the stand-in relay and through a direct
# connection, in the network's own messages and never into the game. A line is shown as "Player 2: hello": the
# sender is a number, since nobody's name goes over the network. What a person typed cannot change the game: a match
# with chat in it ends in the state a match without it does, which these show by the state numbers (a checkpoint
# on every pass) and the pictures agreeing, and by the game's own variables never being the chat's.
class TestLobbyChat < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 24

  # A device that says a line of chat when the pass it names is asked for its buttons, as a person would type one.
  class TalkingDevice < Headless
    attr_writer :lockstep

    def initialize(says: {}, **options)
      super(**options)
      @says = says
    end

    def held_buttons(pass)
      @lockstep.send_chat(@says.fetch(pass)) if @says.key?(pass)
      super
    end
  end

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  private def world
    relay = Network::StandInRelay.new
    [relay, Network::Scheduler.new(movement: -> { relay.pending? })]
  end

  # One copy of a match through the relay: it makes the room (the first) or joins it. +says+ is what its player types, by pass.
  private def copy(relay, scheduler, box, walk, says: {}, host: false, players: 2)
    line = Network::InProcessLine.new(relay.connect, scheduler)
    print = Network::Fingerprint.of(program, title: "WANDERERS")
    lambda do
      lockstep = if host
                   transport = Network::RelayTransport.make_room(line)
                   box.concat([transport.code] * 8)
                   Network::Lockstep.host(transport: transport, fingerprint: print, players: players, seed: 0, input_delay: 2, checkpoint_every: 1)
                 else
                   Network::Lockstep.join(transport: Network::RelayTransport.join_room(line, box.first), fingerprint: print)
                 end
      device = TalkingDevice.new(says: says, frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [walk]] })
      device.lockstep = lockstep
      Session.new(program, network: lockstep).play(device)
      [device, lockstep]
    end
  end

  private def checks(device) = device.pictures.map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  def test_two_copies_exchange_messages_in_a_room_during_the_match
    relay, scheduler = world
    box = []

    outcomes = scheduler.play([copy(relay, scheduler, box, :right, host: true, says: { 6 => "hello from one" }),
                               copy(relay, scheduler, box, :left, says: { 9 => "and from two" })])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    (one, host), (two, guest) = outcomes.map(&:value)
    assert_equal ["Player 2: and from two"], host.chat_lines.map(&:words)
    assert_equal ["Player 1: hello from one"], guest.chat_lines.map(&:words)
    assert_equal checks(one), checks(two)
  end

  def test_players_waiting_in_a_room_chat_before_the_match_begins
    relay, scheduler = world
    box = []
    early = lambda do
      line = Network::InProcessLine.new(relay.connect, scheduler)
      transport = Network::RelayTransport.join_room(line, box.first)
      lockstep = Network::Lockstep.join(transport: transport, fingerprint: Network::Fingerprint.of(program, title: "WANDERERS"))
      lockstep.send_chat("anyone here?")
      Session.new(program, network: lockstep).play(Headless.new(frames: 4))
      lockstep
    end

    outcomes = scheduler.play([copy(relay, scheduler, box, :right, host: true, players: 2), early])

    assert_equal ["Player 2: anyone here?"], outcomes.first.value.last.chat_lines.map(&:words)
  end

  def test_chat_never_changes_the_game
    relay, scheduler = world
    box = []
    talk = { 4 => "a", 5 => "b", 6 => "c", 8 => "d", 13 => "e" }
    chatty = scheduler.play([copy(relay, scheduler, box, :right, host: true, says: talk), copy(relay, scheduler, box, :left, says: talk)])
    other_relay, other_scheduler = world
    other_box = []
    silent = other_scheduler.play([copy(other_relay, other_scheduler, other_box, :right, host: true),
                                   copy(other_relay, other_scheduler, other_box, :left)])

    (chatty + silent).each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    assert_equal checks(silent.first.value.first), checks(chatty.first.value.first), "the same match with and without chat"
  end

  def test_what_a_player_types_is_kept_to_a_line_of_plain_text
    relay, scheduler = world
    box = []
    long = "x" * (Network::Lockstep::MOST_CHAT_CHARACTERS + 50)
    outcomes = scheduler.play([copy(relay, scheduler, box, :right, host: true, says: {}),
                               copy(relay, scheduler, box, :left, says: { 5 => "two\nlines\tand\e[31m", 7 => long })])

    host = outcomes.first.value.last
    texts = host.chat_lines.map(&:text)
    assert_equal "two lines and [31m", texts.first
    assert_equal Network::Lockstep::MOST_CHAT_CHARACTERS, texts.last.length
  end

  def test_a_message_is_sent_to_the_room_and_not_back_to_its_sender
    relay, scheduler = world
    box = []

    outcomes = scheduler.play([copy(relay, scheduler, box, :right, host: true, says: { 5 => "mine" }), copy(relay, scheduler, box, :left)])

    assert_empty outcomes.first.value.last.chat_lines
  end
end
