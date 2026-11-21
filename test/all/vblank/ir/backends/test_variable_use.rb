# frozen_string_literal: true

require "test_helper"

# How often a run names each variable (Backends::VariableUse), the ranking a lowering keeps its
# busiest variables in quick memory by: a number worked on in a loop counts for more than one set
# once a pass, a routine's numbers count at each call, and the game plays the same however they
# rank.
class TestVariableUse < Minitest::Test
  VariableUse = VBlank::IR::Backends::VariableUse

  def test_a_number_in_a_loop_outranks_one_named_once_a_pass
    use = VariableUse.new(built)

    assert_operator use.weight(:inner), :>, use.weight(:outer)
    assert_operator use.weight(:outer), :>, 0
  end

  def test_a_routine_counts_at_each_call
    use = VariableUse.new(built)

    assert_operator use.weight(:in_routine), :>, use.weight(:outer)
  end

  def test_a_variable_the_run_never_names_weighs_nothing
    assert_equal 0, VariableUse.new(built).weight(:never_named)
  end

  def test_the_game_plays_as_the_interpreter_plays_it
    player = game_player
    player.run(built, frames: 5)

    assert_equal 5 * 8 * 3, player[:inner]
  end

  private def built = counting_game.program(console: VBlank::Testing.console)

  private def counting_game
    VBlank.game("VARIABLE USE", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      outer = 0
      inner = 0
      in_routine = 0
      func(:bump) { in_routine += 1 }
      game_loop do
        outer += 1
        repeat(8) do
          inner += 3
          call :bump
        end
      end
    end
  end
end
