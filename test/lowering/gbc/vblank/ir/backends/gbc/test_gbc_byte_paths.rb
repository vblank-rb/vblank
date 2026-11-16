# frozen_string_literal: true

require "test_helper"

# THE QUICK WAYS A COLOR CARTRIDGE TAKES WITH A BYTE written in the program — a comparison with
# one, a number held between two of them, a number times one (Lowering#emit_compare_with_byte,
# #value_of_clamped, #emit_product_by_byte) — give what the long ways give for every number,
# below nought and past a byte included; and so does a number held between two ends of up to
# two bytes, which a read of a table longer than 256 entries is. Every answer is checked against
# the interpreter's on every pass.
class TestGBCBytePaths < Minitest::Test
  STEP = 37

  # Each number a quick way can get wrong: either side of every end the game below writes, the
  # last byte and the first number past it, a number whose low byte is small but whose upper bytes
  # are not, either side of the last two-byte number, and the two ends of a number, which a
  # product wraps past.
  EDGES = [-1, 0, 2, 3, 4, 5, 6, 7, 8, 199, 200, 201, 249, 250, 251, 254, 255, 256, 257, 259,
           298, 299, 300, 301, 556, 39_999, 40_000, 40_001, 65_535, 65_536, 65_537, 65_836,
           -256, -255, -65_536, -65_535, 16_843_009, 0x7FFF_FFFF, -0x8000_0000].freeze

  ANSWERS = %i[below at_most above at_least under_nought at_most_last_byte
               held held_to_byte held_to_one held_to_half held_wide held_to_word
               times_seven times_byte times_three].freeze

  # A table longer than 256 entries, read at the number.
  LONG = Array.new(300) { |i| (i * 3) - 100 }.freeze

  # The answers a number gives, set into the game's variables.
  def answer(answers, n)
    { below: n < 5, at_most: n <= 200, above: n > 255, at_least: n >= 250, under_nought: n < 0,
      at_most_last_byte: n <= 255 }.each do |name, holds|
      if holds
        answers[name] = 1
      else
        answers[name] = 0
      end
    end
    answers[:held] = n.clamp(3, 250)
    answers[:held_to_byte] = n.clamp(0, 255)
    answers[:held_to_one] = n.clamp(7, 7)
    answers[:held_to_half] = n.clamp(0, 299)
    answers[:held_wide] = n.clamp(300, 40_000)
    answers[:held_to_word] = n.clamp(0, 65_535)
    answers[:times_seven] = n * 7
    answers[:times_byte] = n * 255
    answers[:times_three] = n * 3
  end

  # A number walking from far below nought to past a byte.
  private def walking_number
    test = self
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      # Four strides of 9001 from here land on -185, and steps of 37 then walk past 255.
      n = var :n, -36_189
      answers = ANSWERS.to_h { |name| [name, var(name, 0)] }
      steps = table :steps, [3, 1, 4, 1, 5]
      long = table :long, TestGBCBytePaths::LONG, width: :half
      picked = var :picked, 0
      read_long = var :read_long, 0
      game_loop do
        if n.abs < 400
          n += TestGBCBytePaths::STEP
        else
          n += 9_001
        end
        test.answer(answers, n)
        picked = steps[n]
        read_long = long[n]
      end
    end
    b.finalize_program
    b.program
  end

  # Each of EDGES in turn, one a pass.
  private def edge_numbers
    test = self
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      edges = table :edges, TestGBCBytePaths::EDGES, width: :word
      long = table :long, TestGBCBytePaths::LONG, width: :half
      at = var :at, 0
      n = var :n, 0
      read_long = var :read_long, 0
      answers = ANSWERS.to_h { |name| [name, var(name, 0)] }
      game_loop do
        n = edges[at]
        test.answer(answers, n)
        read_long = long[n]
        at += 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_every_answer_is_the_interpreters_for_a_walking_number
    game_player.run(walking_number, frames: 60)
  end

  def test_every_answer_is_the_interpreters_at_each_edge
    game_player.run(edge_numbers, frames: EDGES.size + 2)
  end
end
