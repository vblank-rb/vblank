# frozen_string_literal: true

require "test_helper"

# Numbers the build can prove are small, at the edges of 8 and 16 bits. A console that works such a
# number at 8 or 16 bits (Backends::NumberRanges) still gives the 32-bit answer (IR::Int32): a slot
# of bytes holding 128 reads -128, a half slot holding 32768 reads -32768, the size of -32768 is
# 32768, a shift down of a negative keeps its sign. Each pass reads the next of sixteen edge values
# from lists and tables and counts how often each comparison holds; every run plays it, and a
# checked run holds its build to the interpreter on every pass, so a narrowing that gets an edge
# wrong fails here. The counts are also held to the same sums worked out in Ruby.
class TestValueSmallNumbers < Minitest::Test
  EDGES = [0, 1, -1, 127, 128, -128, -129, 255, 256, 32_767, 32_768, -32_768, -32_769, 15, 16, -16].freeze
  BYTE_STEPS = [-128, -1, 0, 1, 127, 64, -64, 2, -2, 100, -100, 3, -3, 50, -50, 7].freeze
  HALF_STEPS = [-32_768, 32_767, 0, -1, 1, 256, -256, 255, 1000, -1000, 16_384, -16_384, 7, -7, 128, -129].freeze
  PASSES = 40

  # The tests, by the name of the count each adds to, worked out in Ruby from what a pass reads.
  RULES = {
    bytes_ordered: ->(r) { r[:b] < r[:b1] },
    halves_ordered: ->(r) { r[:h] >= r[:h5] },
    mixed_near: ->(r) { (r[:b] - r[:h]).abs < 16 },
    bytes_near: ->(r) { (r[:b] - r[:b3]).abs < 128 },
    shifted_down: ->(r) { (r[:h] >> 4) < -100 },
    sign_only: ->(r) { (r[:h] >> 15) == -1 },
    shifted_up: ->(r) { (r[:b] << 7) > 16_000 },
    table_below: ->(r) { r[:step] < r[:w] - 64 },
    half_table_at_most: ->(r) { r[:half_step] <= r[:h] },
    masked_below: ->(r) { r[:v] < 128 },
    masked_equal: ->(r) { r[:v] == 255 },
    negated: ->(r) { -r[:b] > 100 },
    largest_size: ->(r) { r[:h].abs > 32_767 },
    byte_against_number: ->(r) { r[:b] >= -128 && r[:b] != 127 }
  }.freeze

  def test_comparisons_of_small_numbers_at_their_edges_give_the_32_bit_answer
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: PASSES)

    passes = player[:passes]
    assert_operator passes, :>, 16, "the game played #{passes} passes"
    expected = expected_counts(passes)
    RULES.each_key { |name| assert_equal expected.fetch(name), player[name], "#{name} after #{passes} passes" }
  end

  private def game
    edges, byte_steps, half_steps, rules = EDGES, BYTE_STEPS, HALF_STEPS, RULES
    proc do
      bs = list :bs, capacity: 16, width: :byte, full_of: 0
      hs = list :hs, capacity: 16, width: :half, full_of: 0
      steps = table :steps, byte_steps, width: :byte
      half_steps_table = table :half_steps, half_steps, width: :half
      edges.each_with_index do |edge, at|
        bs[at] = edge
        hs[at] = edge
      end
      counts = rules.keys.to_h { |name| [name, var(name, 0)] }
      passes = var :passes, 0
      t = var :t, 15
      v = var :v, 0
      w = var :w, 0
      game_loop do
        passes.increase!(1)
        t.store!((t + 1) & 15)
        v.store!((v + 37) & 255)
        w.store!((w + 1) & 127)
        b = bs[t]
        h = hs[t]
        {
          bytes_ordered: b < bs[(t + 1) & 15],
          halves_ordered: h >= hs[(t + 5) & 15],
          mixed_near: (b - h).abs < 16,
          bytes_near: (b - bs[(t + 3) & 15]).abs < 128,
          shifted_down: (h >> 4) < -100,
          sign_only: (h >> 15) == -1,
          shifted_up: (b << 7) > 16_000,
          table_below: steps[t] < w - 64,
          half_table_at_most: half_steps_table[t] <= h,
          masked_below: v < 128,
          masked_equal: v == 255,
          negated: -b > 100,
          largest_size: h.abs > 32_767,
          byte_against_number: (b >= -128) & (b != 127)
        }.each { |name, held| counts.fetch(name).increase!(1) if held }
      end
    end
  end

  # What each count is after +passes+ passes, worked out in Ruby.
  private def expected_counts(passes)
    counts = RULES.keys.to_h { |name| [name, 0] }
    t, v, w = 15, 0, 0
    passes.times do
      t = (t + 1) & 15
      v = (v + 37) & 255
      w = (w + 1) & 127
      read = {
        b: byte(EDGES[t]), b1: byte(EDGES[(t + 1) & 15]), b3: byte(EDGES[(t + 3) & 15]),
        h: half(EDGES[t]), h5: half(EDGES[(t + 5) & 15]),
        step: BYTE_STEPS[t], half_step: HALF_STEPS[t], v: v, w: w
      }
      RULES.each { |name, rule| counts[name] += 1 if rule.call(read) }
    end
    counts
  end

  private def byte(number) = ((number + 0x80) & 0xFF) - 0x80
  private def half(number) = ((number + 0x8000) & 0xFFFF) - 0x8000
end
