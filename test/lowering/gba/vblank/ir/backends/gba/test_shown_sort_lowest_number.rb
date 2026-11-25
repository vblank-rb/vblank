# frozen_string_literal: true

require "test_helper"
require "differential"

# A row of sprites each shown under a count test (`if lives > 1`, `if lives > 2`, ...) is asked as
# one run by the sprite order's sort. The count is a signed 32-bit number, so a count at the very
# bottom of the range must show none of them, as the interpreter shows none. A count taken away
# from the first rank would wrap round to a large positive number and show them all.
class TestShownSortLowestNumber < Minitest::Test
  include Differential

  LOWEST = -2_147_483_648

  # Three sprites in a draw order, then each one's showing rewritten as the count test the
  # lowering asks as one run: sprite n shows while `lives > first_rank + n`. The DSL makes that
  # shape only for a pool's places, whose count is never below nothing, so the game is built
  # with the DSL and the three tests are put in its tree here.
  private def hearts_game(lives_at, first_rank:, lives_later: lives_at)
    program = VBlank.game("HEARTS", consoles: %i[gba]) do
      screen :tiled
      image(:heart, "#" => :red) { Array.new(8) { "#" * 8 }.join("\n") }
      lives = var :lives, lives_at
      passes = var :passes, 0
      hearts = Array.new(3) { |n| sprite(:heart, at: [(n * 20) + 20, 40]) }
      draw_in_order(*hearts)
      game_loop do
        passes += 1
        lives = lives_later if passes == 3
        wait_vblank
      end
    end.program
    count_tests = Array.new(3) { |n| VBlank::IR::Build.binop(:>, VBlank::IR::Build.var_ref(:lives), VBlank::IR::Build.int(first_rank + n)) }
    program.walk.select { |node| node.kind == :object }.each_with_index { |node, n| node.active = count_tests[n].copy }
    program.walk.find { |node| node.kind == :list_sort }.shown = count_tests.map(&:copy)
    program
  end

  def test_a_count_at_the_lowest_number_shows_no_heart
    assert_backends_agree(hearts_game(LOWEST, first_rank: 1), frames: 6, name: "HEARTLOW")
  end

  def test_hearts_shown_then_dropped_to_the_lowest_number_all_go
    assert_backends_agree(hearts_game(3, first_rank: 1, lives_later: LOWEST), frames: 8, name: "HEARTDROP")
  end

  def test_a_count_just_above_the_lowest_number_shows_no_heart
    assert_backends_agree(hearts_game(LOWEST + 1, first_rank: 1), frames: 6, name: "HEARTLOW")
  end

  def test_a_count_in_the_middle_of_the_ranks_shows_the_hearts_below_it
    assert_backends_agree(hearts_game(3, first_rank: 1), frames: 6, name: "HEARTMID")
  end

  def test_ranks_from_nought_agree_at_the_lowest_number
    assert_backends_agree(hearts_game(LOWEST, first_rank: 0), frames: 6, name: "HEARTZERO")
  end
end
