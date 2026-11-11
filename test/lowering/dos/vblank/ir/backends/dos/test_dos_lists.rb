# frozen_string_literal: true

require "test_helper"

# LISTS ON A PC, in DOSBox, held to the interpreter (DOS::CheckedRun compares every list and every variable).
# What a list and a pool do is in test/all/vblank/test_list.rb and its neighbours, which this run plays;
# these are what is DOS's own: slots of each width in the data segment, the ring a list goes round as items
# leave its front, a run copied in from a table in another segment, the runtime's sort, and each way a list
# stops a game, in the interpreter's words.
class TestDOSLists < Minitest::Test
  include VBlank::IR::Build

  DOS = VBlank::IR::Backends::DOS
  WIDTHS = %i[byte half word].freeze
  TOO_BIG_FOR_SOME = [200, -129, 70_000, -2_000_000_000, 5].freeze

  private def checked(*statements, frames: nil) = DOS::CheckedRun.new.run(program(screen(:bitmap), *statements, halt, console: :dos), frames: frames)

  # The words the interpreter stops in, and that the DOS program stops in the same ones.
  private def assert_stops_alike(*statements)
    game = program(screen(:bitmap), *statements, halt, console: :dos)
    expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(game, frames: 1) }
    error = assert_raises(VBlank::IR::ProgramError) { DOS::HeadlessRun.new.run(game, frames: 1) }

    assert_equal expected.message, error.message
    expected.message
  end

  # A list of each width takes numbers too big for its slots, gives up items from both ends until its first
  # item has gone round its slots more than once, and is read, written and counted on the way.
  def test_lists_of_every_width_go_round_their_slots
    steps = WIDTHS.flat_map do |width|
      name = :"ring_#{width}"
      [list_new(name, 5, width: width),
       *TOO_BIG_FOR_SOME.map { |value| list_push(name, int(value)) },
       *Array.new(13) do |turn|
         [list_drop(name, from: turn.odd? ? :front : :back), list_push(name, binop(:*, int(turn), int(7_001))),
          list_set(name, int(turn % 5), binop(:+, list_get(name, int((turn + 2) % 5)), int(turn))),
          set(:"#{name}_sum", binop(:+, var_ref(:"#{name}_sum"), binop(:+, list_get(name, int(turn % 5)), list_len(name))))]
       end.flatten]
    end
    run = checked(*steps)

    assert_equal [5, 5, 5], WIDTHS.map { |width| run.list(:"ring_#{width}").length }
    refute_equal run[:ring_byte_sum], run[:ring_word_sum], "a slot of a byte keeps less of each number than a whole one"
  end

  # A list made full of a number, then runs of it set, a count of nought or less setting none.
  def test_a_list_made_full_and_runs_of_it_filled
    run = checked(list_new(:cells, 9, width: :half, full_of: -3),
                  list_fill(:cells, from: int(2), count: int(4), value: int(40_000)),
                  list_fill(:cells, from: int(8), count: int(1), value: int(7)),
                  list_fill(:cells, from: int(100), count: int(0), value: int(1)),
                  list_fill(:cells, from: int(0), count: int(-5), value: int(1)))

    assert_equal [-3, -3, -25_536, -25_536, -25_536, -25_536, -3, -3, 7], run.list(:cells), "40,000 in a slot of two bytes is -25,536"
  end

  # A run of a table copied in from any place asked for, held so the run stays inside the table, at each
  # width of table into each width of list.
  def test_runs_of_a_table_copied_into_lists
    entries = [3, 200, -7, 127, 90, 1_000, -30_000, 65]
    steps = [table(:levels, entries, width: :half, signed: true), table(:small, [1, 2, 250, 4, 5], width: :byte, signed: false),
             *WIDTHS.flat_map do |width|
               [list_new(:"from_levels_#{width}", 4, width: width), list_new(:"from_small_#{width}", 3, width: width)]
             end,
             *[-2, 0, 3, 5, 99].each_with_index.flat_map do |at, turn|
               WIDTHS.flat_map do |width|
                 [list_copy(:"from_levels_#{width}", table: :levels, at: int(at), count: 4),
                  list_copy(:"from_small_#{width}", table: :small, at: int(at), count: 3),
                  set(:"seen_#{width}_#{turn}", binop(:+, list_get(:"from_levels_#{width}", int(3)), list_get(:"from_small_#{width}", int(0))))]
               end
             end]
    run = checked(*steps)

    assert_equal [90, 1_000, -30_000, 65], run.list(:from_levels_word), "from 99, held to the last four"
    assert_equal [-6, 4, 5], run.list(:from_small_byte), "250 in a slot of a byte"
  end

  # Items put in order by the numbers another list holds at them, smallest first and biggest first, level
  # ones left as they stood, in a list whose first item is part way round its slots.
  def test_a_list_put_in_order_by_another_lists_numbers
    weights = [50, -4, 50, 9, -4, 300, 0, 50]
    steps = [list_new(:weights, 8), *weights.map { |weight| list_push(:weights, int(weight)) },
             list_new(:order, 8, width: :byte), list_push(:order, int(0)), list_push(:order, int(0)), list_drop(:order, from: :front),
             list_drop(:order, from: :front), *[7, 2, 5, 0, 4, 1, 6, 3].map { |item| list_push(:order, int(item)) },
             list_new(:other, 8, width: :byte), *[7, 2, 5, 0, 4, 1, 6, 3].map { |item| list_push(:other, int(item)) },
             list_sort(:order, by: :weights), list_sort(:other, by: :weights, descending: true)]
    run = checked(*steps)

    assert_equal [4, 1, 6, 3, 7, 2, 0, 5], run.list(:order), "-4 twice, 0, 9, then the three 50s as they stood, then 300"
    assert_equal [5, 7, 2, 0, 3, 6, 4, 1], run.list(:other), "300, the three 50s as they stood, 9, 0, then -4 twice"
  end

  # Each way a list stops a game: an index outside it either way, a run filled past its end, an item added
  # to a full list, one taken from an empty list at either end, and an item put in order that is no place
  # in the list of numbers.
  def test_a_list_stops_the_game_in_the_interpreters_words
    made = [list_new(:few, 3, width: :half), list_push(:few, int(1)), list_push(:few, int(2))]
    said = [[*made, set(:read, list_get(:few, int(2)))], [*made, list_set(:few, int(-1), int(9))],
            [*made, list_fill(:few, from: int(1), count: int(3), value: int(0))],
            [*made, list_push(:few, int(3)), list_push(:few, int(4))],
            [list_new(:none, 2), list_drop(:none, from: :front)], [list_new(:none, 2), list_drop(:none, from: :back)],
            [*made, list_new(:keys, 2), list_push(:keys, int(0)), list_sort(:few, by: :keys)]].map { |steps| assert_stops_alike(*steps) }

    assert_equal 7, said.uniq.size, "seven different things said"
  end

  # A fill of no items asks nothing else, so a place it could not have read stops nothing; and what it would
  # have been set to is worked out only when something is set.
  def test_a_fill_of_no_items_does_not_work_out_where_or_what
    run = checked(list_new(:few, 3), list_push(:few, int(5)), set(:count, int(0)),
                  list_fill(:few, from: list_get(:few, int(9)), count: var_ref(:count), value: list_get(:few, int(9))),
                  list_fill(:few, from: int(0), count: binop(:+, var_ref(:count), int(1)), value: binop(:*, list_get(:few, int(0)), int(3))))

    assert_equal [15], run.list(:few)
  end

  # A run longer than its table, or than the list it is copied into, stops the game where the copy is
  # reached, in the words every cartridge's reader has for it, and a game that never reaches it plays on.
  def test_a_copy_that_cannot_fit_stops_the_game_only_where_it_is_reached
    entries = table(:levels, [1, 2, 3, 4, 5, 6], width: :byte, signed: false)
    too_long = [entries, list_new(:few, 3), list_copy(:few, table: :levels, at: int(0), count: 5)]
    past_table = [entries, list_new(:many, 20), list_copy(:many, table: :levels, at: int(0), count: 9)]
    said = [too_long, past_table].map do |steps|
      assert_raises(VBlank::IR::ProgramError) { DOS::HeadlessRun.new.run(program(screen(:bitmap), *steps, halt, console: :dos), frames: 1) }.message
    end
    never_reached = DOS::HeadlessRun.new.run(program(screen(:bitmap), set(:on, int(0)), entries, list_new(:few, 3),
                                                     if_(var_ref(:on), list_copy(:few, table: :levels, at: int(0), count: 5)),
                                                     set(:reached, int(1)), halt, console: :dos), frames: 1)

    assert_match(/5 entries does not fit list :few \(capacity 3\)/, said.first)
    assert_match(/9 entries is longer than its table \(6 entries\)/, said.last)
    assert_equal 1, never_reached[:reached]
  end

  # More items than a list's ring can count is refused as the game is built, in plain words.
  def test_a_list_too_long_for_a_pc_is_refused
    error = assert_raises(DOS::LoweringError) { DOS.new.build(program(screen(:bitmap), list_new(:huge, 40_000, width: :byte), halt, console: :dos)) }

    assert_match(/holds 40000 items/, error.message)
    assert_match(/make the list shorter/, error.message)
  end
end
