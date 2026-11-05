# frozen_string_literal: true

require "test_helper"

# A LIST OF PLACES PUT IN ORDER BY THE NUMBERS ANOTHER LIST HOLDS (list_sort) on the console,
# against the interpreter. The console walks the list by address, a slot's width a step, and finds
# each place's number by shifting it by the other list's width, so what is worth checking is every
# width either list can be, numbers below nothing, level numbers (whose order must not change),
# both directions, and a list with nothing before its first item to stop the walk.
class TestListSort < Minitest::Test
  include VBlank::IR::Build

  PLACES = [5, 3, 0, 7, 1, 6, 2, 4].freeze
  # Level pairs (places 0 and 2, 3 and 6) and numbers below nothing.
  NUMBERS = [40, -7, 40, 100_000, -300, 3, 100_000, -7].freeze

  # The places sorted by the numbers, every place read back into :item0, :item1, ...
  private def sorted(order_width, key_width, descending: false, places: PLACES, numbers: NUMBERS)
    program(
      list_new(:order, [places.length, 1].max, width: order_width),
      *places.map { |place| list_push(:order, place) },
      list_new(:keys, numbers.length, width: key_width),
      *numbers.map { |number| list_push(:keys, number) },
      list_sort(:order, by: :keys, descending: descending),
      *Array.new(places.length) { |i| set(:"item#{i}", list_get(:order, i)) },
      halt,
    )
  end

  private def items_on_console(prog, count)
    backend = GBA.new
    rom = VBlank::Cartridge::ROM.assemble(backend.lower(prog), title: "LISTSORT")
    v = assert_emulator_loads_rom(rom, frames: 2, vars: backend.var_addresses)
    Array.new(count) { |i| v.var(:"item#{i}") }
  end

  private def items_on_interpreter(prog, count)
    i = Reference.new.run(prog)
    Array.new(count) { |n| i[:"item#{n}"] }
  end

  private def assert_sorted_alike(*widths, **options)
    prog = sorted(*widths, **options)
    count = (options[:places] || PLACES).length
    want = items_on_interpreter(prog, count)

    assert_equal want, items_on_console(prog, count)
    want
  end

  def test_byte_places_by_word_numbers_rise_with_level_ones_in_order
    assert_equal [4, 7, 1, 5, 0, 2, 3, 6], assert_sorted_alike(:byte, :word)
  end

  def test_byte_places_by_word_numbers_fall_with_level_ones_in_order
    assert_equal [3, 6, 0, 2, 5, 7, 1, 4], assert_sorted_alike(:byte, :word, descending: true)
  end

  def test_half_places_by_half_numbers = assert_sorted_alike(:half, :half, numbers: [40, -7, 40, 9_000, -300, 3, 9_000, -7])
  def test_word_places_by_byte_numbers = assert_sorted_alike(:word, :byte, numbers: [40, -7, 40, 100, -100, 3, 100, -7])

  def test_one_item_and_none_stay_as_they_are
    assert_equal [0], assert_sorted_alike(:byte, :word, places: [0], numbers: [5])
    assert_equal [], assert_sorted_alike(:byte, :word, places: [], numbers: [5])
  end
end
