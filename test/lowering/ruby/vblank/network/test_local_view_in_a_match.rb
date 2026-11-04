# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# WHICH PLAYER I AM, IN A MATCH. Each machine of a match is a different player, and the game may
# draw that (examples/wanderers.rb puts an arrow over the machine's own walker) but may not keep it.
# These play wanderers as a match of two and four machines, with a checkpoint on every pass, so any
# difference in what the game remembers is named at once.
class TestLocalViewInAMatch < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  Build = VBlank::IR::Build

  PASSES = 12

  # Where the four walkers start on the Advance's screen. Each machine presses `a`, which joins its
  # player and moves nobody, so they stay there.
  STARTS = Wanderers::Layout.new(width: 240, height: 160).starts

  # A pixel of the arrow over a walker at [x, y]: the arrow is the 8x8 tile just above the walker,
  # and its stem is in columns 3 and 4 of its sixth row.
  private def arrow_pixel(x, y) = [x + 3, y - 8 + 5]

  # The players whose walker has the arrow over it in +picture+.
  private def marked_players(picture)
    STARTS.each_with_index.filter_map do |(x, y), index|
      px, py = arrow_pixel(x, y)
      index + 1 if picture.pixels[(py * picture.width) + px] == white(picture)
    end
  end

  # The arrow is white, and white is the largest number a pixel can hold, so it is the picture's largest.
  private def white(picture) = picture.pixels.max

  private def machines(count, program, press: :right)
    net = Network::SimulatedNetwork.new
    copies = Array.new(count) do
      endpoint = net.connect
      fingerprint = Network::Fingerprint.of(program, title: "VIEW")
      lockstep = if endpoint.id == 1
                   Network::Lockstep.host(transport: endpoint, fingerprint: fingerprint, players: count, seed: 5,
                                          input_delay: 1, checkpoint_every: 1)
                 else
                   Network::Lockstep.join(transport: endpoint, fingerprint: fingerprint)
                 end
      device = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [press]] })
      [Session.new(program, network: lockstep), device]
    end
    [net, copies]
  end

  private def play(net, copies)
    net.play(copies.map { |session, device| -> { session.play(device) } })
  end

  # Each picture as a number, with the four places an arrow can be in left out.
  private def pictures_without_arrows(device)
    arrow_boxes = STARTS.map { |x, y| [(x...(x + 8)), ((y - 8)...y)] }
    device.pictures.map do |picture|
      kept = picture.pixels.each_with_index.reject do |_pixel, index|
        arrow_boxes.any? { |xs, ys| xs.cover?(index % picture.width) && ys.cover?(index / picture.width) }
      end
      Zlib.crc32(kept.map(&:first).pack("V*"))
    end
  end

  def test_each_of_four_machines_marks_its_own_walker_and_all_agree_on_every_pass
    program = Wanderers::GAME.checked_program(err: nil, console: :gba)
    net, copies = machines(4, program, press: :a)

    outcomes = play(net, copies)

    outcomes.each_with_index { |outcome, index| assert_nil outcome.error, "machine #{index + 1}: #{outcome.error.inspect}" }
    copies.each.with_index(1) do |(_session, device), machine|
      assert_equal [machine], marked_players(device.pictures.last), "machine #{machine} marks its own walker alone"
    end
    agreeing = copies.map { |_session, device| pictures_without_arrows(device) }
    assert_equal 1, agreeing.uniq.size, "every picture is the same away from the arrows"
  end

  def test_two_machines_agree_on_every_pass_while_the_marked_walkers_move
    program = Wanderers::GAME.checked_program(err: nil, console: :gba)
    net, copies = machines(2, program)

    outcomes = play(net, copies)

    outcomes.each_with_index { |outcome, index| assert_nil outcome.error, "machine #{index + 1}: #{outcome.error.inspect}" }
  end

  # What would happen with no guard: a game that keeps the number in a variable plays differently
  # on each machine, and the match says so at the first checkpoint. The guard is what stops a game
  # being written like this (test_local_view.rb), so this one is built by hand.
  def test_a_game_that_keeps_the_player_number_in_a_variable_would_desync
    keeps = Build.program(Build.set(:mine, 0),
                          Build.loop_(Build.wait_vblank, Build.set(:mine, Build.local_player)),
                          console: :gba, players: [1, 2], for_computer: true)
    net, copies = machines(2, keeps)

    outcomes = play(net, copies)

    assert_kind_of Network::Desync, outcomes.first.error
  end

  def test_a_game_for_one_player_is_refused_a_match_in_plain_words
    alone = Build.program(Build.loop_(Build.wait_vblank), console: :gba, for_computer: true)

    error = assert_raises(ArgumentError) { machines(2, alone) }

    assert_match(/for one player, so it cannot play in a match/, error.message)
  end
end
