# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"
require "sprite_count_cost_games"

# What an order of seven costs on the Game Boy Color, measured in the emulator. The sort is written
# in the Color's own code with both lists' places known, a compare an item when nobody passed
# anybody, so working out the seven numbers and sorting them is a few of the frame's 154 lines.
# Placing the sprites in a worked-out order costs little more than placing them in a fixed one: a
# sprite whose place in the order held is left as it is in the sprite table, as the frame's other
# sprites are, and each place in the order is one byte read. So the whole order is the sort and
# a line or two.
class TestGBCDrawInOrderCost < Minitest::Test
  # The routine that works out the numbers and sorts them, as a share of the frame.
  private def sort_share
    DrawOrderCostGames.profile(:gbc, ordered: true).game.select { |row| row.routine.to_s.include?("__draw_order_1__sort") }
                      .sum(&:share)
  end

  def test_working_out_and_sorting_seven_takes_a_few_lines
    share = sort_share

    assert_operator share, :<, 0.06, "the sort takes #{(share * 154).round(1)} of the frame's 154 lines"
  end

  def test_an_order_of_seven_costs_under_ten_lines
    share = DrawOrderCostGames.share_of_frame(:gbc)

    assert_operator share, :<, 0.06, "an order of seven costs #{(share * 154).round(1)} of the frame's 154 lines"
  end

  # Passes of +game+ played in thirty frames, and the frames.
  private def passes_in_thirty_frames(game)
    result = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
                 .profile(out: StringIO.new, frames: 30)
    [result.passes, result.frames]
  end

  # Measured: a pass took two frames before the sort was written out a place at a time.
  def test_a_pool_of_thirty_two_moving_in_order_keeps_a_pass_a_frame
    passes, frames = passes_in_thirty_frames(DrawOrderCostGames.drifting_pool_game(:gbc, 32))

    assert_equal frames, passes, "every pass fits in one frame"
  end

  # Every thing passes every other each pass. Measured: a pass took three frames before the sort
  # turned a run standing the wrong way round over at once.
  def test_a_pool_of_thirty_two_whose_order_turns_round_keeps_a_pass_a_frame
    passes, frames = passes_in_thirty_frames(DrawOrderCostGames.reversed_pool_game(:gbc, 32))

    assert_equal frames, passes, "every pass fits in one frame"
  end

  # The checked run compares the sprites drawn, back to front, with the interpreter's after every
  # pass, and stops at the first that differs.
  def test_a_pool_of_thirty_two_moving_in_order_is_drawn_as_the_interpreter_draws_it
    game_player.run(DrawOrderCostGames.drifting_pool_game(:gbc, 32).program(console: :gbc), frames: 140)
  end

  def test_a_pool_of_thirty_two_whose_order_turns_round_is_drawn_as_the_interpreter_draws_it
    game_player.run(DrawOrderCostGames.reversed_pool_game(:gbc, 32).program(console: :gbc), frames: 8)
  end

  # A place of an order is written short. The Color sees its cartridge a bank of 16 KB at a time (Pan
  # Docs, "MBC5"), and the sort is written out a place at a time in the bank of the code that runs it,
  # so every byte a place takes is a byte that code cannot have. A place is its number, its step of
  # the sort and of the walk, the test of whether it shows, and the test of its flag with a call to
  # the code every place shares where it turned over (Lowering::ShownSort). A pool's place is a
  # compare of its count and stays under 104 bytes; a sprite's test reads its own four-byte flag and
  # stays under 168. With the flag's work written out at every place they were 118 and 183.
  BYTES_A_POOL_PLACE = 104
  BYTES_A_SPRITE = 168

  def test_each_place_of_a_pool_in_an_order_adds_under_a_hundred_and_four_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:gbc, :pool, 36)

    assert_operator bytes, :<, BYTES_A_POOL_PLACE, "each place of the pool added #{bytes.round(1)} bytes"
  end

  def test_each_sprite_in_an_order_adds_under_a_hundred_and_sixty_eight_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:gbc, :sprites, 36)

    assert_operator bytes, :<, BYTES_A_SPRITE, "each sprite added #{bytes.round(1)} bytes"
  end
end
