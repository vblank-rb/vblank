# frozen_string_literal: true

require "test_helper"

# ONE GAME FILE, A DEFAULT FOR EACH WAY IT IS BUILT. A cartridge and a build for a computer are
# made from the same block, which asks `built_for_computer?` as it runs.
class TestBuiltForComputer < Minitest::Test
  private def game
    VBlank.game "ASKS", consoles: %i[gba] do
      var :music, built_for_computer? ? 1 : 0
      var :seen, 0
      game_loop {}
    end
  end

  private def music_in(program) = Reference.new.run(program, frames: 2)[:music]

  def test_a_cartridge_is_not_built_for_a_computer
    assert_equal 0, music_in(game.build_rom(profile: false, out: nil, err: nil).source_program)
  end

  def test_the_tree_a_test_asks_for_is_the_cartridge_tree
    assert_equal 0, music_in(game.program)
  end

  def test_a_game_built_as_c_is_built_for_a_computer
    assert_equal 1, music_in(VBlank::IR::Backends::Native.new.checked_program(game, err: nil))
  end

  def test_a_game_built_for_a_web_page_is_built_for_a_computer
    assert_equal 1, music_in(VBlank::IR::Backends::JS.new.checked_program(game, err: nil))
  end

  def test_a_game_played_as_ruby_is_built_for_a_computer
    assert_equal 1, music_in(game.checked_program(err: nil))
  end
end
