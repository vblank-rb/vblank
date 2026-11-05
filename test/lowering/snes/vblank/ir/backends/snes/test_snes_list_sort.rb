# frozen_string_literal: true

require "test_helper"

# A LIST PUT IN ORDER, written in place in the Super Nintendo's own code (Lowering#emit_list_sort),
# for each width its two lists can keep: the list of places and the list of numbers each a byte,
# a half or a word. The numbers have level ones, so a sort that is not stable swaps them, and ones
# below nought and past 16 bits, so a compare that is not signed, or not whole, puts them in the
# wrong place. Each pass the numbers change, so the list starts each sort from the last one's
# order, with things to move past. Checked against the interpreter after every pass.
class TestSNESListSort < Minitest::Test
  B = VBlank::IR::Build

  WIDTHS = %i[byte half word].freeze
  # The numbers at each place, and what is added to them each pass, one place in five rising past
  # the rest.
  NUMBERS = [7, -2, 7, 30, 0, -40, 7, 12].freeze

  private def program(order_width, key_width, descending:)
    places = NUMBERS.length
    big = key_width == :word ? 70_000 : 1
    B.program(
      B.screen(:tiled),
      B.list_new(:order, places, width: order_width),
      *(0...places).map { |place| B.list_push(:order, (place * 3) % places) },
      B.list_new(:numbers, places, width: key_width),
      *NUMBERS.map { |number| B.list_push(:numbers, number * big) },
      B.set(:pass, 0),
      B.loop_(
        B.list_sort(:order, by: :numbers, descending: descending),
        B.add(:pass, 1),
        B.list_set(:numbers, B.binop(:%, B.var_ref(:pass), places),
                   B.binop(:+, B.list_get(:numbers, B.binop(:%, B.var_ref(:pass), places)), 9 * big)),
        B.wait_vblank
      )
    ).tap { |made| made.console = :snes }
  end

  WIDTHS.each do |order_width|
    WIDTHS.each do |key_width|
      define_method(:"test_#{order_width}_places_by_#{key_width}_numbers_rising_and_falling") do
        [false, true].each do |descending|
          VBlank::IR::Backends::SNES::CheckedRun.new.run(program(order_width, key_width, descending: descending), frames: 12)
        end
      end
    end
  end
end
