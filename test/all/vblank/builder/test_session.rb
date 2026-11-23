# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/session_files/heap_shelf"

# One game being built at a time on a thread (Builder::Session). A class's names follow the class:
# a game file one game's block brings in is Ruby's for every later game too, so a later game using
# its class builds as the game that brought it in does.
class TestSession < Minitest::Test
  # A game file brought in by a game's own block records its names on the main Ractor alone, as
  # every game file does as it loads.
  runs_on_the_main_ractor!

  private def built(&block)
    VBlank::Cartridge::EvaluatedGame.new(VBlank::DSL::PlainRuby.rewrite(block, checked: false)).program
  end

  # Public: a game block calls it back through `test`.
  def bring_in_heap_reader
    VBlank.require_game_file VBlank.root.join("test/fixtures/session_files/heap_reader").to_s
  end

  # Bumps the shelf's middle heap on every pass, at a place the game works out.
  private def bumping_game(brings_in:)
    test = self
    built do
      test.bring_in_heap_reader if brings_in
      shelf = HeapShelf.new
      reader = HeapReader.new(shelf)
      at = 0
      n = 0
      game_loop do
        at = 1
        reader.bump(at)
        n = shelf.heaps[1]
      end
    end
  end

  def test_a_class_an_earlier_games_block_brought_in_builds_in_a_later_game
    built do
      VBlank.require_game_file VBlank.root.join("test/fixtures/session_files/heap_reader").to_s
      game_loop {}
    end
    player = game_player
    player.run(bumping_game(brings_in: false), frames: 3)

    assert_equal 5, player[:n]
  end

  def test_a_game_bringing_in_a_class_itself_builds
    player = game_player
    player.run(bumping_game(brings_in: true), frames: 3)

    assert_equal 5, player[:n]
  end
end
