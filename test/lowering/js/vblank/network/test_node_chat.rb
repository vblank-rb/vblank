# frozen_string_literal: true

require "test_helper"
require "node_copy"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# CHAT BETWEEN A COPY BUILT AS JAVASCRIPT AND A RUBY BUILD, in a match, in the network's own messages: each sees
# the other's lines as "Player N: text", and the game goes on as it would without them, which the state
# number of every pass (a checkpoint on every pass) and the pictures agreeing show.
class TestNodeChat < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session

  PASSES = 24
  RIGHT = 1 << 4

  # A device that types a line when the pass it names asks for its buttons.
  class TalkingDevice < VBlank::Live::Headless
    attr_writer :lockstep

    def initialize(says:, **options)
      super(**options)
      @says = says
    end

    def held_buttons(pass)
      @lockstep.send_chat(@says.last) if pass == @says.first
      super
    end
  end

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_mark: false })

  private def settings = { seed: 0, input_delay: 2, checkpoint_every: 1, players: 2 }

  def test_a_node_copy_and_a_ruby_build_exchange_lines_and_the_game_is_the_same
    net = Network::SimulatedNetwork.new
    node = NodeCopy.copy(program, endpoint: net.connect, passes: PASSES, hold: RIGHT, host: settings, says: [6, "hello from node"])
    endpoint = net.connect
    lockstep = Network::Lockstep.join(transport: endpoint, fingerprint: Network::Fingerprint.of(program, title: "WANDERERS"))
    device = TalkingDevice.new(says: [9, "hello from ruby"], frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [:left]] })
    device.lockstep = lockstep
    ruby = -> { Session.new(program, network: lockstep).play(device) && device }

    outcomes = net.play([node, ruby])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    played = outcomes.first.value
    assert played.success, played.error
    assert_equal [[2, "hello from ruby"]], played.chats
    assert_equal ["Player 1: hello from node"], lockstep.chat_lines.map(&:words)
    assert_equal device.pictures.first(PASSES - 1).map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }, played.pictures
  end
end
