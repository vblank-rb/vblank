# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# WHICH PLAYER I AM, IN A MATCH. Each machine of a match is a different player, and the game may
# draw that (examples/wanderers.rb says "YOU 2" on the second player's screen) but may not keep it.
# These play wanderers as a match of two and four machines, with a checkpoint on every pass, so any
# difference in what the game remembers is named at once.
class TestLocalViewInAMatch < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  Build = VBlank::IR::Build

  PASSES = 12

  # The rows of the corner where wanderers says which player this is.
  CORNER_ROWS = (8..16)

  private def machines(count, program)
    net = Network::SimulatedNetwork.new
    copies = Array.new(count) do
      endpoint = net.connect
      print = Network::Fingerprint.of(program, title: "VIEW")
      lockstep = if endpoint.id == 1
                   Network::Lockstep.host(transport: endpoint, fingerprint: print, players: count, seed: 5,
                                          input_delay: 1, checkpoint_every: 1)
                 else
                   Network::Lockstep.join(transport: endpoint, fingerprint: print)
                 end
      device = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [:right]] })
      [Session.new(program, network: lockstep), device]
    end
    [net, copies]
  end

  private def play(net, copies)
    net.play(copies.map { |session, device| -> { session.play(device) } })
  end

  # Each picture's rows outside the corner line, as a number, and the corner's alone.
  private def pieces_of(device)
    device.pictures.map do |picture|
      rows = picture.pixels.each_slice(picture.width).to_a
      corner = rows.values_at(*CORNER_ROWS).flatten
      elsewhere = rows.each_with_index.reject { |_row, index| CORNER_ROWS.cover?(index) }.flat_map(&:first)
      [Zlib.crc32(elsewhere.pack("v*")), Zlib.crc32(corner.pack("v*"))]
    end
  end

  def test_four_machines_say_who_they_are_and_still_agree_on_every_pass
    program = Wanderers::GAME.checked_program(err: nil, console: :gba)
    net, copies = machines(4, program)

    outcomes = play(net, copies)

    outcomes.each_with_index { |outcome, index| assert_nil outcome.error, "machine #{index + 1}: #{outcome.error.inspect}" }
    pieces = copies.map { |_session, device| pieces_of(device) }
    assert_equal 1, pieces.map { |each_copy| each_copy.map(&:first) }.uniq.size, "everything but the corner is the same"
    corners = pieces.map { |each_copy| each_copy.last.last }
    assert_equal 4, corners.uniq.size, "each machine says a different player"
  end

  # What would happen with no guard: a game that keeps the number in a variable plays differently
  # on each machine, and the match says so at the first checkpoint. The guard is what stops a game
  # being written like this (test_local_view.rb), so this one is built by hand.
  def test_a_game_that_keeps_the_player_number_in_a_variable_would_desync
    keeps = Build.program(Build.set(:mine, 0),
                          Build.loop_(Build.wait_vblank, Build.set(:mine, Build.local_player)),
                          console: :gba, for_computer: true)
    net, copies = machines(2, keeps)

    outcomes = play(net, copies)

    assert_kind_of Network::Desync, outcomes.first.error
  end
end
