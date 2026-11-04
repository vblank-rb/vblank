# frozen_string_literal: true

require "test_helper"
require "node_copy"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# COPIES OF A GAME BUILT AS JAVASCRIPT, PLAYED BY NODE, IN A MATCH (rg_lockstep.js, the same session as
# Network::Lockstep): beside each other under every delay a test sets, and beside a Ruby build of the same game,
# which they must agree with on the fingerprint and on the number for the game's state on every pass (a
# checkpoint on every pass makes the machines compare it). The match is carried by test/node_copy.rb.
class TestNodeLockstep < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 30
  RIGHT = 1 << 4
  LEFT = 1 << 5

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  private def settings(players, delay: 2) = { seed: 5, input_delay: delay, checkpoint_every: 1, players: players }

  private def node(net, hold:, host: nil)
    NodeCopy.copy(program, endpoint: net.connect, passes: PASSES, hold: hold, host: host)
  end

  # A Ruby copy as the second machine of the match, walking the way +buttons+ says.
  private def ruby_copy(net, walk, host: nil)
    endpoint = net.connect
    print = Network::Fingerprint.of(program, title: "WANDERERS")
    lockstep = if host
                 Network::Lockstep.host(transport: endpoint, fingerprint: print, players: host[:players], seed: host[:seed],
                                        input_delay: host[:input_delay], checkpoint_every: host[:checkpoint_every])
               else
                 Network::Lockstep.join(transport: endpoint, fingerprint: print)
               end
    device = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [walk]] })
    session = Session.new(program, network: lockstep)
    -> { session.play(device) && device }
  end

  private def pictures_of(device) = device.pictures.first(PASSES - 1).map { |picture| Zlib.crc32(picture.pixels.pack("v*")) }

  def test_two_node_copies_agree_on_every_pass_under_every_delay_the_test_sets
    [[0, 0], [1, 2], [2, 5], [4, 1]].each do |input_delay, rounds|
      net = Network::SimulatedNetwork.new
      (1..2).to_a.permutation(2) { |from, to| net.delay(from: from, to: to, rounds: rounds) }
      copies = [node(net, hold: RIGHT, host: settings(2, delay: input_delay)), node(net, hold: LEFT)]

      first, second = net.play(copies).map { |outcome| outcome.error ? raise(outcome.error) : outcome.value }

      assert first.success, first.error
      assert second.success, second.error
      assert_equal PASSES - 1, first.states.size, "delay #{input_delay}, link #{rounds}"
      assert_equal first.states, second.states
      assert_equal first.pictures, second.pictures
    end
  end

  def test_a_node_copy_and_a_ruby_copy_carry_the_same_fingerprint
    net = Network::SimulatedNetwork.new
    played = net.play([node(net, hold: RIGHT, host: settings(2)), node(net, hold: LEFT)]).map(&:value)

    ours = Network::Fingerprint.of(program, title: "WANDERERS")
    played.each { |copy| assert_equal [ours.console, ours.digest], copy.fingerprint }
  end

  def test_a_node_copy_and_a_ruby_copy_agree_on_every_pass_picture_and_state
    net = Network::SimulatedNetwork.new
    outcomes = net.play([node(net, hold: RIGHT, host: settings(2)), ruby_copy(net, :left)])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    node_side = outcomes.first.value
    assert node_side.success, node_side.error
    assert_equal pictures_of(outcomes.last.value), node_side.pictures
  end

  def test_a_ruby_copy_hosts_and_a_node_copy_joins_and_they_agree
    net = Network::SimulatedNetwork.new
    outcomes = net.play([ruby_copy(net, :right, host: settings(2)), node(net, hold: LEFT)])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    assert outcomes.last.value.success, outcomes.last.value.error
    assert_equal pictures_of(outcomes.first.value), outcomes.last.value.pictures
  end

  def test_a_player_who_goes_is_seen_leaving_on_the_same_pass_by_a_node_copy
    net = Network::SimulatedNetwork.new
    net.at_round(6) { net.disconnect(3) }
    copies = [node(net, hold: RIGHT, host: settings(3, delay: 1)), node(net, hold: LEFT), ruby_copy(net, :up)]

    outcomes = net.play(copies)

    first = outcomes.first.value
    assert first.success, first.error
    assert_equal 1, first.events.count { |_pass, kind, _player| kind == :left }
    assert_equal first.events, outcomes[1].value.events
  end
end
