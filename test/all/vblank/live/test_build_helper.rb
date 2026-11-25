# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "all/vblank/cartridge/test_game_register"

# The game `vblank run` builds in its helper process is the one the game file names: a handle it
# registered, or the whole game when it names none.
class TestBuildHelper < Minitest::Test
  # Every test loads a game file, as the helper does, which only the main Ractor may.
  runs_on_the_main_ractor!

  include RoomsGameFile

  private def rooms_told(game) = game_player.run(game.program(console: game_console), frames: 1)[:rooms_told]

  def test_load_game_takes_the_handle_the_file_registers
    Dir.mktmpdir do |folder|
      game = VBlank::Live::BuildHelper.load_game(rooms_file(folder, "game.with_features(:rooms).with_settings(rooms: 3).register"))

      assert_equal 4323, rooms_told(game)
    end
  end

  def test_load_game_takes_the_handle_write_if_main_was_called_on
    Dir.mktmpdir do |folder|
      game = VBlank::Live::BuildHelper.load_game(rooms_file(folder, "game.with_features(:rooms).with_settings(rooms: 2).write_if_main(settings: { other: 1 })"))

      assert_equal 4322, rooms_told(game)
    end
  end

  def test_load_game_of_a_file_that_names_no_handle_takes_the_whole_game
    Dir.mktmpdir do |folder|
      game = VBlank::Live::BuildHelper.load_game(rooms_file(folder, ""))

      error = assert_raises(VBlank::BuildError) { game.program(console: game_console) }
      assert_match REFUSAL, error.message
    end
  end
end
