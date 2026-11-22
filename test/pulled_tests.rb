# frozen_string_literal: true

# A gamepad's triggers part pulled (`pulled(:l2)`), as a build for a computer reads them: the
# desktop window, `vblank run` and the web page hand the runtime how far each trigger is pulled
# (IR::Buttons.pull_shift). No console's own pad reads a trigger part pulled, so these are not in
# test/all/ or test/console/: they are played through game_player by the interpreter
# (test/interpreter/vblank/builder/test_pulled_interpreter.rb) and the game as C, as JavaScript
# and as Ruby, checked against it on every frame (test/lowering/{native,js,ruby}/.../test_*_pulled.rb).
# What a cartridge answers is test/all/vblank/builder/test_pulled.rb's and
# test/console/ps1/vblank/builder/test_input_on_the_playstation.rb's.
module PulledTests
  # Built as a PlayStation game for a computer, as the runs that play it build it.
  BUILT_FOR_COMPUTER = VBlank::Cartridge::Options.new(console: :ps1, for_computer: true)

  # How far each trigger is pulled on the last pass, for players 1 and 2, and how many passes L2
  # was held.
  private def triggers
    builder = VBlank::Builder.new(options: BUILT_FOR_COMPUTER)
    builder.instance_eval do
      left = var :left, 0
      right = var :right, 0
      second_left = var :second_left, 0
      held_left = var :held_left, 0
      game_loop do
        left = pulled(:l2)
        right = pulled(:r2)
        second_left = pulled(:l2, player: 2)
        held_left += 1 if held(:l2)
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_trigger_reads_how_far_it_is_pulled
    run = game_player.hold(l2: 40, r2: 100).run(triggers, frames: 3)

    assert_equal [40, 100], [run[:left], run[:right]]
  end

  # A trigger counts as held from IR::Buttons::HELD_FROM, and reads its pull below it too.
  def test_a_trigger_is_held_from_a_small_pull
    held_from = VBlank::IR::Buttons::HELD_FROM
    pulls = { 1 => held_from - 1, 2 => held_from - 1, 3 => held_from, 4 => held_from }
    run = game_player.input_each_frame { |frame| [{ l2: pulls.fetch(frame, 0) }] }.run(triggers, frames: 6)

    assert_equal 2, run[:held_left]
  end

  # A test that holds the trigger with no pull, as a key does, holds it all the way.
  def test_a_trigger_held_as_a_button_is_pulled_all_the_way
    run = game_player.hold(:l2).run(triggers, frames: 3)

    assert_equal [100, 0], [run[:left], run[:right]]
  end

  def test_the_second_players_trigger_is_theirs
    run = game_player.hold(p2_l2: 60).run(triggers, frames: 3)

    assert_equal [0, 60], [run[:left], run[:second_left]]
  end
end
