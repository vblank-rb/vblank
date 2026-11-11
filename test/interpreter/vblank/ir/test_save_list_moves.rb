# frozen_string_literal: true

require "test_helper"

# A WHOLE LIST MOVED TO OR FROM SAVE MEMORY IN ONE STEP (IR save_store_list, save_load_list) means
# exactly the loops it stands for (IR::SaveListMoves.loops_for): the same bytes in save memory and
# the same list. The interpreter runs the step itself, so this holds its own reading of the step to
# the loops every backend without a routine of its own lowers.
class TestSaveListMoves < Minitest::Test
  include VBlank::IR::Build

  Moves = VBlank::IR::SaveListMoves
  AT = 0x200

  # A list of +width+ holding +items+, stored at AT, emptied, given two other items, and loaded
  # back +count+ long. The steps are run as they are, or written out as their loops.
  private def stored_and_loaded(width, items, count:, as_loops:)
    store = save_store_list(:kept, at: AT, width: width, index: :at_item)
    load = save_load_list(:kept, at: AT, count: var_ref(:wanted), most: 6, width: width, index: :at_item)
    moves = [store, list_drop(:kept, from: :back), list_push(:kept, 77), list_push(:kept, 78), load]
    moves = moves.flat_map { |node| Moves::KINDS.include?(node.kind) ? Moves.loops_for(node) : [node] } if as_loops
    program(set(:at_item, 0), set(:wanted, count), list_new(:kept, 8, width: width),
            *items.map { |item| list_push(:kept, item) }, *moves, halt)
  end

  private def played(program)
    store = SaveImage.new
    run = Reference.new(save: store).run(program, frames: 1)
    [run.list(:kept), store.to_sav]
  end

  def test_a_list_stored_and_loaded_in_one_step_is_the_loops_it_stands_for
    { byte: [1, 200, 3, 255, 5], half: [1, 40_000, -3, 4], word: [1, -2, 70_000, 2_000_000_000] }.each do |width, items|
      [items.length, 2, 0, 99, -4].each do |count|
        whole = played(stored_and_loaded(width, items, count: count, as_loops: false))
        loops = played(stored_and_loaded(width, items, count: count, as_loops: true))

        assert_equal loops, whole, "a #{width} list loaded #{count} long"
      end
    end
  end

  # What the step does, said on its own: a byte list keeps the low eight bits, and reads them back
  # the way the list reads a number too big for it.
  def test_a_byte_list_comes_back_as_the_list_keeps_its_items
    list, = played(stored_and_loaded(:byte, [1, 200, 3], count: 3, as_loops: false))

    assert_equal [1, -56, 3], list
  end

  def test_a_load_longer_than_the_step_allows_is_held_to_its_most
    list, = played(stored_and_loaded(:word, [1, 2, 3, 4, 5, 6, 7], count: 99, as_loops: false))

    assert_equal [1, 2, 3, 4, 5, 6], list
  end
end
