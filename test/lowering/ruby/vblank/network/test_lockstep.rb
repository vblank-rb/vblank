# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# TWO AND FOUR COPIES OF ONE GAME PLAYING ONE MATCH (examples/wanderers.rb built as Ruby), joined
# by a simulated network that lives in this process and that the test controls: a message can be
# late, held back, or never sent because its sender left. Each copy is a Live::Session with its own
# headless window and a Network::Lockstep, and the test runs them side by side, a round at a time.
# Nothing here waits for a clock or draws a random number of its own, so every run is the same run.
class TestLockstep < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  # The bit the right button is in a player's buttons (IR::Buttons::NAMES lists a, b, select, start, right).
  RIGHT_BIT = 1 << 4

  # Wanderers says which player each machine is, in a corner of the screen, so no two machines show the
  # same picture. These tests are about the pictures agreeing, so they leave that line out.
  NO_LINE = { you_line: false }.freeze

  # How long each machine plays, in passes (pictures shown).
  PASSES = 40

  # What each machine's own person holds. Player 1 walks right and player 2 walks left, and the
  # other two walk up and down. Every machine reads its own controller as the plain names.
  WALKS = { 1 => :right, 2 => :left, 3 => :up, 4 => :down }.freeze

  private def program
    @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: NO_LINE)
  end

  private def fingerprint(of = program, title: "WANDERERS") = Network::Fingerprint.of(of, title: title)

  # The buttons machine +player+ holds on each pass: its own walk from the second pass on.
  private def walking(player, passes: PASSES)
    (2..passes).to_h { |pass| [pass, [WALKS.fetch(player)]] }
  end

  # One machine: a copy of the game, its window, and the end of its link to the match.
  Copy = Data.define(:session, :device, :lockstep)

  private def copy_for(net, seed: 7, players: 2, delay: 2, checkpoint_every: 4, game: program, title: "WANDERERS",
                       buttons: nil, passes: PASSES)
    endpoint = net.connect
    player = endpoint.id
    lockstep = if player == 1
                 Network::Lockstep.host(transport: endpoint, fingerprint: fingerprint(game, title: title), players: players,
                                        seed: seed, input_delay: delay, checkpoint_every: checkpoint_every)
               else
                 Network::Lockstep.join(transport: endpoint, fingerprint: fingerprint(game, title: title))
               end
    device = Headless.new(frames: passes, buttons: buttons || walking(player, passes: passes))
    Copy.new(session: Session.new(game, network: lockstep), device: device, lockstep: lockstep)
  end

  private def play(net, copies)
    net.play(copies.map { |copy| -> { copy.session.play(copy.device) } })
  end

  private def match_of(count, **options)
    net = Network::SimulatedNetwork.new
    copies = Array.new(count) { copy_for(net, players: count, **options) }
    [net, copies]
  end

  # Every copy showed the same picture on every pass it played.
  private def assert_same_pictures(copies)
    first = picture_checks(copies.first)
    copies.drop(1).each_with_index do |copy, index|
      theirs = picture_checks(copy)
      assert_equal first.size, theirs.size, "copy #{index + 2} played as many passes"
      first.each_index { |pass| assert_equal first[pass], theirs[pass], "pass #{pass + 1} differs on copy #{index + 2}" }
    end
  end

  # A number for each picture a copy showed, so that a failure does not print a screen.
  private def picture_checks(copy) = copy.device.pictures.map { |picture| picture_check(picture.pixels) }
  private def picture_check(pixels) = Zlib.crc32(pixels.pack("v*"))

  private def assert_all_finished(outcomes)
    outcomes.each_with_index { |outcome, index| assert_nil outcome.error, "copy #{index + 1} ended with #{outcome.error.inspect}" }
  end

  def test_two_copies_show_the_same_picture_on_every_pass
    net, copies = match_of(2)

    assert_all_finished play(net, copies)

    assert_equal PASSES, copies.first.device.pictures.size
    assert_same_pictures(copies)
  end

  def test_each_copy_reads_its_own_player_and_the_others_over_the_network
    net, copies = match_of(2)
    play(net, copies)

    # Both walked, so the picture differs from one in which nobody pressed anything, and from one in
    # which only the first player did.
    idle_net, idle = match_of(2, buttons: {})
    play(idle_net, idle)
    only_net = Network::SimulatedNetwork.new
    only = [copy_for(only_net, buttons: walking(1)), copy_for(only_net, buttons: {})]
    play(only_net, only)

    final = ->(copy) { picture_checks(copy).last }
    refute_equal final.call(idle.first), final.call(copies.first)
    refute_equal final.call(only.first), final.call(copies.first)
  end

  def test_four_copies_show_the_same_picture_on_every_pass
    net, copies = match_of(4)

    assert_all_finished play(net, copies)

    assert_same_pictures(copies)
    refute_equal picture_checks(copies.first)[1], picture_checks(copies.first).last, "the walkers moved"
  end

  # THE NETWORK IS SLOWER OR FASTER and the match does not notice: the same pictures, whatever the
  # delay on each link and whatever input delay the host picked.
  def test_copies_agree_under_every_delay_the_test_sets
    [[0, 0], [0, 1], [1, 3], [2, 7], [5, 2]].each do |input_delay, rounds|
      net, copies = match_of(3, delay: input_delay)
      (1..3).to_a.permutation(2) { |from, to| net.delay(from: from, to: to, rounds: rounds + from) }

      assert_all_finished play(net, copies)

      assert_same_pictures(copies)
      assert_equal PASSES, copies.last.device.pictures.size, "input delay #{input_delay}, link delay #{rounds}"
    end
  end

  def test_a_message_held_back_stalls_the_match_until_it_is_let_go_and_then_nothing_was_lost
    net, copies = match_of(2)
    net.hold(from: 2, to: 1)
    net.at_round(30) { net.release(from: 2, to: 1) }

    assert_all_finished play(net, copies)

    assert_same_pictures(copies)
    assert_operator net.round, :>, 30, "copy 1 waited for what was held back"
  end

  def test_a_held_message_nobody_will_release_is_said_in_words
    net, copies = match_of(2)
    net.hold(from: 2, to: 1)

    error = assert_raises(Network::Scheduler::Stalled) { play(net, copies) }

    assert_match(/Held back: 2 to 1/, error.message)
  end

  def test_the_host_picks_the_seed_and_the_same_seed_always_plays_the_same_match
    last_picture = ->(seed) { match_picture(seed) }

    assert_equal last_picture.call(3), last_picture.call(3)
    assert_operator (1..6).map { |seed| last_picture.call(seed) }.uniq.size, :>, 1, "another seed gave another match"
  end

  private def match_picture(seed)
    net, copies = match_of(2, seed: seed)
    play(net, copies)
    copies.first.device.pictures.last.pixels
  end

  # A COPY WHOSE RANDOM NUMBERS DIFFER is not the same game, and the match says so at the first
  # checkpoint it can: the report names the pass and the last one where every machine agreed.
  def test_a_copy_given_another_seed_is_reported_at_the_first_checkpoint
    net, copies = match_of(2, checkpoint_every: 4)
    copies.last.lockstep.define_singleton_method(:seed) { 99_999 }

    outcomes = play(net, copies)

    outcomes.each do |outcome|
      assert_kind_of Network::Desync, outcome.error
      assert_equal 4, outcome.error.report.pass
      assert_equal 0, outcome.error.report.last_agreed_pass
    end
    assert_match(/pass 4/, outcomes.first.error.message)
  end

  # With a checkpoint on every pass, the first pass that differs is named exactly.
  def test_a_copy_given_another_seed_is_reported_on_the_first_pass_when_every_pass_is_a_checkpoint
    net, copies = match_of(2, checkpoint_every: 1)
    copies.last.lockstep.define_singleton_method(:seed) { 99_999 }

    outcomes = play(net, copies)

    assert_equal [1, 1], outcomes.map { |outcome| outcome.error.report.pass }
  end

  def test_four_copies_agree_with_a_different_delay_on_every_link
    net, copies = match_of(4, delay: 1)
    (1..4).to_a.permutation(2) { |from, to| net.delay(from: from, to: to, rounds: (from * 3) + to) }

    assert_all_finished play(net, copies)

    assert_same_pictures(copies)
  end

  def test_a_copy_that_goes_wrong_part_way_is_reported_at_the_first_checkpoint_after_it
    net, copies = match_of(2, checkpoint_every: 4)
    corrupt_buttons_from_pass(copies.last, 10)

    outcomes = play(net, copies)

    report = outcomes.first.error.report
    assert_equal 12, report.pass
    assert_equal 8, report.last_agreed_pass
    assert_equal [1, 2], report.crcs.keys.sort
    refute_equal report.crcs[1], report.crcs[2]
  end

  def test_a_copy_of_a_different_game_is_refused_at_the_handshake_in_plain_words
    net = Network::SimulatedNetwork.new
    host = copy_for(net, players: 2)
    intruder = copy_for(net, game: other_game, title: "OTHER")
    friend = copy_for(net)

    outcomes = play(net, [host, intruder, friend])

    assert_nil outcomes[0].error
    assert_nil outcomes[2].error
    assert_kind_of Network::Refused, outcomes[1].error
    assert_equal :different_game, outcomes[1].error.reason
    assert_match(/different game.*WANDERERS.*OTHER/m, outcomes[1].error.message)
    assert_same_pictures([host, friend])
  end

  # The room is the relay's, and a machine that has joined it hears every message of the room, the
  # match's start too, though the host has not let it in.
  def test_a_machine_that_asks_to_join_after_the_match_has_started_is_refused_and_does_not_play
    net = Network::SimulatedNetwork.new
    host = copy_for(net, players: 2)
    friend = copy_for(net)
    late = copy_for(net)

    outcomes = play(net, [host, friend, late])

    assert_nil outcomes[0].error
    assert_nil outcomes[1].error
    assert_includes %i[started full], outcomes[2].error.reason
    assert_empty late.device.pictures
    assert_same_pictures([host, friend])
  end

  def test_a_copy_built_for_another_console_is_refused_and_told_which
    net = Network::SimulatedNetwork.new
    host = copy_for(net, players: 2)
    colour = copy_for(net, game: Wanderers::GAME.checked_program(err: nil, console: :gbc, settings: NO_LINE))
    friend = copy_for(net)

    outcomes = play(net, [host, colour, friend])

    assert_equal :different_console, outcomes[1].error.reason
    assert_match(/Game Boy Advance.*Game Boy Color/m, outcomes[1].error.message)
    assert_nil outcomes[0].error
  end

  def test_a_player_who_leaves_is_seen_leaving_on_the_same_pass_by_everybody_and_nobody_stalls
    net, copies = match_of(3, delay: 1)
    net.at_round(12) { net.disconnect(3) }

    outcomes = play(net, copies)

    assert_all_finished outcomes
    left = copies.first(2).map { |copy| copy.lockstep.events.select { |event| event.kind == :left } }
    assert_equal 1, left.first.size
    assert_equal left.first, left.last
    assert_equal 3, left.first.first.player
    copies.first(2).each { |copy| assert_equal ["Player 3 left the match."], copy.device.notices }
    assert_same_pictures(copies.first(2))
    assert_equal PASSES, copies.first.device.pictures.size
  end

  # The tape holds the presses and not the match's seed, so this match uses seed 0, which adds nothing
  # to the game's own, and the interpreter, which knows no match, draws the same colours.
  def test_the_match_is_kept_as_a_tape_the_interpreter_plays_to_the_same_picture
    net, copies = match_of(2, seed: 0)
    play(net, copies)

    tape = copies.first.lockstep.tape
    assert_equal tape.to_s, copies.last.lockstep.tape.to_s
    assert_equal true, tape.in_passes
    played = tape.play(unbuilt(program), on: "interpreter")

    assert_equal picture_checks(copies.first).last, picture_check(played.game.frame_gba)
  end

  # A game that is not wanderers, for the same console.
  private def other_game
    VBlank.game("OTHER", consoles: %i[gba], players: 4) { game_loop { pixel 2, 2, :red } }.checked_program(err: nil, console: :gba)
  end

  private def unbuilt(of) = VBlank::Playthroughs::UnbuiltGame.new(of, title: "WANDERERS", source: "wanderers")

  # Makes copy +copy+ be told other buttons than the ones sent, from pass +from+ on, as a
  # bug in a machine would.
  private def corrupt_buttons_from_pass(copy, from)
    transport = copy.lockstep.instance_variable_get(:@transport)
    transport.define_singleton_method(:receive_message) do
      super()&.then do |envelope|
        message = envelope.message
        next envelope unless message.is_a?(Network::Buttons) && message.pass >= from

        Network::Envelope.new(from: envelope.from, message: message.with(mask: message.mask ^ RIGHT_BIT))
      end
    end
  end
end
