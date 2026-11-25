# frozen_string_literal: true

require "test_helper"

# A test reads a running game's variables by their names (IR::ReadingByName), on whichever player
# the run hands it. A name the game never declared is refused in plain words, naming the closest
# names it has, rather than read as 0: a test left reading a name a rename took away would
# otherwise keep passing every "it stays 0" assertion.
class TestReadingByName < Minitest::Test
  def test_a_declared_variable_reads_its_number
    player = played_counter

    assert_equal 3, player[:count]
    assert_equal 3, player.var(:count)
  end

  def test_a_name_the_game_never_declared_is_refused_with_the_closest_names
    player = played_counter

    error = assert_raises(ArgumentError) { player[:cuont] }
    assert_match(/no variable :cuont/, error.message)
    assert_match(/:count/, error.message)
    refute_match(/__/, error.message, "the framework's own variables are not offered")
  end

  def test_a_name_close_to_none_is_refused_listing_the_games_names
    error = assert_raises(ArgumentError) { played_counter.var(:nope) }

    assert_match(/no variable :nope/, error.message)
    assert_match(/:cost, :count/, error.message)
  end

  def test_var_asks_whether_a_name_exists_without_raising
    player = played_counter

    assert player.var?(:count)
    refute player.var?(:nope)
  end

  private

  # A game that counts its passes, played three frames.
  def played_counter
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      count = var(:count, 0)
      cost = var(:cost, 0)
      game_loop do
        count += 1
        cost += 2
      end
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)
    player
  end
end
