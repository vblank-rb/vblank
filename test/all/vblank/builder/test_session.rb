# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/session_files/heap_shelf"

# One game being built at a time on a thread (Builder::Session): what one build learns from the
# game files it brings in stays with that build, so two games built in turn build as each does
# alone.
class TestSession < Minitest::Test
  # A game file brought in by a game's own block records its names on the main Ractor alone, as
  # every game file does as it loads.
  runs_on_the_main_ractor!

  private def built(&block)
    VBlank::Cartridge::EvaluatedGame.new(VBlank::DSL::PlainRuby.rewrite(block, checked: false)).program.to_h
  end

  # Reads the shelf's middle heap, a place known while building.
  private def shelf_game
    built do
      shelf = HeapShelf.new
      n = 0
      game_loop { n = shelf.heaps[1] }
    end
  end

  # A game that brings in a file changing a slot of any `heaps` at a place it works out. Read by
  # the build of the shelf game, that would make the shelf's heaps a list the game changes.
  private def heap_reader_game
    built do
      VBlank.require_game_file VBlank.root.join("test/fixtures/session_files/heap_reader").to_s
      game_loop {}
    end
  end

  def test_two_games_built_in_turn_build_as_each_does_alone
    alone = shelf_game
    heap_reader_game

    assert_equal alone, shelf_game
  end

  # The game that brings the file in reads what it names, on the first build that loads it and on
  # every later one: the shelf's heaps are a list the game keeps there.
  def test_a_file_a_games_block_brings_in_counts_for_that_build
    2.times do
      program = built do
        VBlank.require_game_file VBlank.root.join("test/fixtures/session_files/heap_reader").to_s
        shelf = HeapShelf.new
        n = 0
        game_loop { n = shelf.heaps[1] }
      end

      assert_includes program.to_s, "heap_shelf_heaps"
    end
  end
end
