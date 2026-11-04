# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# THINGS A GAME CAN ASK THAT COULD BE DIFFERENT ON EACH MACHINE: how many frames have gone by, what
# the clock says, and what the random numbers hold. In a match every machine runs the whole game, so
# one number that differs sends the machines different ways. Each is settled here, and each has a
# test that shows the trouble is real where the game is not held to it, and that a match is not
# troubled.
#
# - FRAMES. The interpreter counts the frames a pass took, so a slow machine counts more. The game
#   as Ruby (and as C and JavaScript) counts passes: one for each pass, however long it took, so
#   `frames_since_power_on` and a `once_a_frame` body are the same on every machine.
# - THE CLOCK. A match has none: `clock.present?` is false on every machine, so no machine's own
#   time reaches the game. The Ruby window never gave the game the computer's clock anyway.
# - THE RANDOM NUMBERS. `randomize` stirs the game's stream one step and uses nothing of the
#   machine's, so every machine stirs the same way; the match's seed is the one number that is
#   shared at the start (Network::Lockstep).
class TestWhatDiffersBetweenMachines < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  PASSES = 20

  private def counting_game
    VBlank.game("COUNTS", consoles: %i[gba], players: 2) do
      ticks = var :ticks, 0
      seen = var :seen, 0
      once_a_frame { ticks.increase!(1) }
      game_loop do
        seen.store!(frames_since_power_on)
        draw_number :seen, 10, 10, :white, digits: 4
        draw_number :ticks, 10, 30, :white, digits: 4
      end
    end
  end

  private def clock_game
    VBlank.game("CLOCKS", consoles: %i[gba], players: 2) do
      game_loop { pixel 3, 3, :white if clock.present? }
    end
  end

  private def stirring_game
    VBlank.game("STIRS", consoles: %i[gba], players: 2) do
      pick = var :pick, 0
      game_loop do
        randomize
        pick.store!(rand(0..9)) if held(:a, player: 1) || held(:a, player: 2)
        draw_number :pick, 10, 10, :white, digits: 2
      end
    end
  end

  # Two machines of one match; the second is given +pass_seconds+ for each pass, so its window is slow.
  private def match(game, second_speed: 0, buttons: {})
    program = game.checked_program(err: nil, console: :gba)
    fingerprint = Network::Fingerprint.of(program, title: "TEST")
    net = Network::SimulatedNetwork.new
    copies = Array.new(2) do |index|
      endpoint = net.connect
      lockstep = if index.zero?
                   Network::Lockstep.host(transport: endpoint, fingerprint: fingerprint, players: 2, seed: 3, input_delay: 1,
                                          checkpoint_every: 1)
                 else
                   Network::Lockstep.join(transport: endpoint, fingerprint: fingerprint)
                 end
      speed = index.zero? ? 0 : second_speed
      [Session.new(program, network: lockstep), Headless.new(frames: PASSES, buttons: buttons, pass_seconds: speed)]
    end
    outcomes = net.play(copies.map { |session, device| -> { session.play(device) } })
    [outcomes, copies.map(&:last)]
  end

  private def assert_no_errors(outcomes)
    outcomes.each_with_index { |outcome, index| assert_nil outcome.error, "machine #{index + 1}: #{outcome.error.inspect}" }
  end

  private def interpreter_after(game, late: nil)
    interpreter = Reference.new
    interpreter.frames_each_pass { late } if late
    interpreter.run(game.checked_program(err: nil, console: :gba), frames: 10)
    interpreter
  end

  def test_the_interpreter_counts_frames_so_a_late_pass_would_split_two_machines
    on_time = interpreter_after(counting_game)[:seen]
    late = interpreter_after(counting_game, late: 2)[:seen]

    assert_operator late, :>, on_time
  end

  def test_a_slow_machine_and_a_quick_one_count_the_same_passes
    outcomes, devices = match(counting_game, second_speed: 1)

    assert_no_errors outcomes
    assert_equal devices.first.pictures.map(&:pixels), devices.last.pictures.map(&:pixels)
  end

  def test_two_interpreters_with_different_clocks_would_split
    clocked = VBlank.game("CLOCKED", consoles: %i[gba]) do
      hour = var :hour, 0
      game_loop { hour.store!(clock.hour) }
    end
    hours = [Time.utc(2030, 1, 1, 9), Time.utc(2030, 1, 1, 17)].map do |time|
      interpreter = Reference.new
      interpreter.clock_at(time)
      interpreter.run(clocked.checked_program(err: nil, console: :gba), frames: 3)
      interpreter[:hour]
    end

    assert_equal [9, 17], hours
  end

  def test_a_match_has_no_clock_on_any_machine
    outcomes, devices = match(clock_game)

    assert_no_errors outcomes
    devices.each { |device| assert_equal [0], device.pictures.last.pixels.uniq, "nothing drawn: no clock was there" }
  end

  def test_randomize_stirs_every_machine_the_same_way
    presses = (5..PASSES).to_h { |pass| [pass, [:a]] }
    outcomes, devices = match(stirring_game, buttons: presses)

    assert_no_errors outcomes
    assert_equal devices.first.pictures.map(&:pixels), devices.last.pictures.map(&:pixels)
  end
end
