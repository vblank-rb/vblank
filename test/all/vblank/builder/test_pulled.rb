# frozen_string_literal: true

require "test_helper"

# How far a button is pulled (`pulled`), as every run plays it. Every console's pad is all or
# nothing, so a button reads 100 while held and 0 when not, however far a test holds it. A gamepad's
# triggers part pulled on a computer are test/pulled_tests.rb's; the PlayStation's L2 and R2 are
# test/console/ps1/vblank/builder/test_input_on_the_playstation.rb's.
class TestPulled < Minitest::Test
  # `total` adds up how far A is pulled on each pass, and `last` keeps the last pass's.
  private def adding_up_a
    builder = VBlank::Builder.new
    builder.instance_eval do
      total = var :total, 0
      last = var :last, 0
      game_loop do
        last = pulled(:a)
        total += last
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_button_reads_a_full_pull_while_held_and_none_when_let_go
    run = game_player.input_each_frame { |frame| frame.between?(2, 4) ? [:a] : [] }.run(adding_up_a, frames: 8)

    assert_equal [300, 0], [run[:total], run[:last]]
  end

  # A pad's button is up or down: held part of the way, it is held, and reads all of the way.
  def test_a_button_held_part_of_the_way_reads_a_full_pull
    run = game_player.hold(a: 40).run(adding_up_a, frames: 3)

    assert_equal VBlank::IR::Buttons::FULL_PULL, run[:last]
  end

  def test_pulled_of_any_button_is_refused
    error = assert_raises(ArgumentError) { VBlank::Builder.new.instance_eval { pulled(:any) } }

    assert_match(/name the button/, error.message)
  end

  def test_pulled_by_any_player_is_refused
    error = assert_raises(ArgumentError) { VBlank::Builder.new.instance_eval { pulled(:r2, player: :any) } }

    assert_match(/give a number/, error.message)
  end

  def test_an_unknown_button_is_refused
    assert_raises(ArgumentError) { VBlank::Builder.new.instance_eval { pulled(:turbo) } }
  end
end
