# frozen_string_literal: true

require "test_helper"
require "stringio"
require "draw_order_cost_games"
require "sprite_count_cost_games"

# WHAT AN ORDER THAT TAKES TURNS COSTS ON THE GENESIS, measured in the emulator. A console's own
# games turn their sprite table round every frame by walking their sprites from one end or the
# other, so the work grows with how many sprites there are and fits in a frame with plenty to
# spare. The same must be true here: a pass a frame, and twice the things about twice the work.
class TestDrawInOrderCost < Minitest::Test
  BLOCK = Array.new(16) { "#" * 16 }.join("\n").freeze

  # +count+ sprites, standing apart, in one order that takes turns.
  def self.sprites_game(count)
    block = BLOCK
    VBlank.game("TURNS SPRITES", consoles: %i[genesis]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      things = Array.new(count) { |i| sprite :"thing_#{i}", at: [(i * 13) % 200, (i * 7) % 120], facing: { down: :block } }
      draw_in_order(*things, take_turns: true)
      game_loop {}
    end
  end

  # A pool of +count+, every one of them spawned, in an order that takes turns, or in none.
  def self.pool_game(count, turns:)
    block = BLOCK
    VBlank.game("TURNS POOL", consoles: %i[genesis]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      crowd = pool :crowd, x: 0, y: 0, capacity: count, image: :block
      draw_in_order(crowd, take_turns: true) if turns
      count.times { |i| crowd.spawn(x: (i * 13) % 200, y: (i * 7) % 120) }
      game_loop {}
    end
  end

  private def profile(game) = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
                                  .profile(out: StringIO.new, frames: 20)

  private def assert_a_pass_a_frame(game)
    result = profile(game)

    assert_equal({ 1 => 20 }, result.passes_by_frames, "every pass fits in one frame")
    result
  end

  def test_fifteen_sprites_taking_turns_take_a_frame_a_pass
    assert_a_pass_a_frame(self.class.sprites_game(15))
  end

  # A console's own games sort their sprites by height every frame with a list of indexes in work
  # memory, and a pool of 32 so sorted fits in a frame even when every one of them passes every
  # other (Lowering#emit_keyed_sort).
  def test_a_pool_of_thirty_two_sorted_by_a_key_takes_a_frame_a_pass
    passes = DrawOrderCostGames.passes_by_frames(:genesis, DrawOrderCostGames.reversed_pool_game(:genesis, 32))

    assert_equal({ 1 => 20 }, passes, "every pass fits in one frame")
  end

  # The order's own work is what the frame spends beyond the same pool with no order. Work that
  # grew with the square of the count would be four times as much for twice the things.
  def test_a_pool_taking_turns_takes_a_frame_a_pass_and_work_that_grows_with_its_size
    work = [16, 32].to_h do |count|
      ordered = assert_a_pass_a_frame(self.class.pool_game(count, turns: true))
      plain = profile(self.class.pool_game(count, turns: false))
      [count, plain.idle_share - ordered.idle_share]
    end

    assert_operator work[16], :>, 0
    assert_operator work[32], :<, work[16] * 2.5, "twice the things, about twice the work: #{work.inspect}"
  end

  # AN ORDER WORKED OUT FROM WHERE EVERYTHING STANDS: seven things sorted by height every pass, as
  # a console's own games sort their sprites, cost the tightest frame a few of its 262 lines, and
  # thirty under a thirteenth of them. The cost is each thing's number worked out, the sort, and
  # each sprite's placing picked by the order (Lowering::Picture#emit_ordered_run).
  BOUND_SEVEN = 3
  BOUND_THIRTY = 20

  def test_an_order_of_seven_costs_its_tightest_frame_a_few_lines
    cost = DrawOrderCostGames.lines_off_tightest_frame(:genesis, sprites: 4)

    assert_operator cost, :<=, BOUND_SEVEN, "an order of seven costs its tightest frame #{cost.round(2)} lines"
  end

  def test_an_order_of_thirty_costs_under_a_thirteenth_of_the_frame
    cost = DrawOrderCostGames.lines_off_tightest_frame(:genesis, sprites: 27)

    assert_operator cost, :<=, BOUND_THIRTY, "an order of thirty costs #{cost.round(2)} lines"
  end

  # A PLACE OF AN ORDER IS WRITTEN SHORT. The Genesis runs its code straight from the cartridge, so
  # code costs room in the cartridge rather than in a quick memory, but the sort is written out a
  # place at a time, and a game of a few dozen places pays every byte of a place many times over.
  # A place is its number, its step of the sort and of the walk, the test of whether it shows, and
  # the test of its flag with a call to the code every place shares where it turned over
  # (Lowering::ShownSort): under 112 bytes. With the flag's work written out at every place it was
  # more than 120.
  BYTES_A_PLACE = 112

  def test_each_place_of_a_pool_in_an_order_adds_under_a_hundred_and_twelve_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:genesis, :pool, 48)

    assert_operator bytes, :<, BYTES_A_PLACE, "each place of the pool added #{bytes.round(1)} bytes"
  end

  def test_each_sprite_in_an_order_adds_under_a_hundred_and_twelve_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:genesis, :sprites, 48)

    assert_operator bytes, :<, BYTES_A_PLACE, "each sprite added #{bytes.round(1)} bytes"
  end
end
