# frozen_string_literal: true

require "test_helper"
require "fixtures/writer_names_of_two_games/turning_game"
require "fixtures/writer_names_of_two_games/knob_game"

# A part's number changed through its writer anywhere in a game's files (`dial.level += 3`) is a
# game variable wherever game code reads it, decided from the writer's name. The names a game's
# files change are that game's: two games built in one process each keep the variables they keep
# when built alone, so a test run and `vblank build` lay a game's memory and save out alike.
class TestPlainRubyWriterNames < Minitest::Test
  # The turning game's dial is read before the line that turns it, and reads as Ruby's does.
  def test_a_number_changed_through_a_writer_in_the_games_files_is_the_games
    player = game_player
    player.run(WriterNamesTurningGame.game.program(console: VBlank::Testing.console), frames: 3)

    assert_equal 7, player[:seen], "1, then 4, then 7"
  end

  # The knob game's knob has a `level` writer too, and nothing in its files changes it, so its
  # level stays Ruby's however many other games in the process change a `level`.
  def test_a_writer_name_in_another_games_files_leaves_this_games_numbers_alone
    program = WriterNamesKnobGame.game.program(console: VBlank::Testing.console)
    player = VBlank::IR::Backends::Reference.new.run(program, frames: 2)

    assert_equal 5, player[:seen]
    assert_empty player.vars.keys.grep(/knob_level/), "the knob's level is not a game variable"
  end
end
