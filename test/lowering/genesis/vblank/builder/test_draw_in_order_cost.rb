# frozen_string_literal: true

require "test_helper"
require "stringio"
require "draw_order_cost_games"

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
  # a console's own games sort their sprites, cost a few of the frame's 262 lines, and thirty under
  # a thirteenth of them. The cost is each thing's number worked out, the sort, and each sprite's
  # placing picked by the order (Lowering::Picture#emit_ordered_run).
  BOUND_SEVEN = 3
  BOUND_THIRTY = 20

  # The lines of the picture in one frame.
  LINES_A_FRAME = 262

  # The lines the order costs a frame, over the frames measured: the share of the frame it takes
  # (DrawOrderCostGames.share_of_frame), which is read from the emulator's own count and never
  # rounded.
  private def lines_order_costs_each_frame(sprites)
    DrawOrderCostGames.share_of_frame(:genesis, sprites: sprites) * LINES_A_FRAME
  end

  # The lines the order costs the tightest frame, one where two things pass: the whole lines that
  # frame has to spare without the order, less those with it. Each of the two is rounded down to
  # a line, so this reads a line over or under what the order costs, and the same order can read
  # a line more when the game without it gets faster. Only a bound with more than a line of room
  # is held to it.
  private def lines_order_costs_tightest_frame(sprites)
    spare = ->(ordered) { DrawOrderCostGames.profile(:genesis, ordered: ordered, sprites: sprites).fewest_lines_spare }
    spare.call(false) - spare.call(true)
  end

  def test_an_order_of_seven_costs_a_few_lines
    cost = lines_order_costs_each_frame(4)

    assert_operator cost, :<=, BOUND_SEVEN, "an order of seven costs #{cost.round(2)} lines"
  end

  def test_an_order_of_thirty_costs_under_a_thirteenth_of_the_frame
    cost = lines_order_costs_tightest_frame(27)

    assert_operator cost, :<=, BOUND_THIRTY, "an order of thirty costs #{cost} lines"
  end
end
