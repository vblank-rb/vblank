# frozen_string_literal: true

require "test_helper"

# A WHOLE LIST MOVED BETWEEN SAVE MEMORY AND THE GAME AS A BLOCK, in a console's own routines, held
# to the interpreter: the same list back and the same bytes in save memory. The cases are the ones
# a block copy can get wrong where an item at a time could not: a list whose oldest item is not in
# its first slot (it is a ring), slots of each width, a run that crosses 8K of save memory (a bank's
# end on the Color), and a list with nothing in it.
#
# Included by each console whose lowering moves the block itself, which says its console
# (+moved_on+) and its checked run (+checked_run+).
module SaveListMoveTests
  include VBlank::IR::Build

  SaveImage = VBlank::IR::SaveImage
  Reference = VBlank::IR::Backends::Reference

  ITEMS = { byte: [1, 200, 3, 4, 5, 250, 7, 8], half: [1, 40_000, 3, -4, 5, 600, 7, 8], word: [1, -2, 70_000, 4, 5, 6, -7, 8] }.freeze

  # A list of six slots of +width+ taken round its ring: five items in, three out of the front,
  # three more in, so its oldest item is in the fourth slot and its newest have come round to the
  # first. It is written at +at+, and a second list is made from what was written, +count+ long.
  private def round_the_ring(width, at:, count:)
    items = ITEMS.fetch(width)
    program(set(:slot, 0), set(:seen, 0),
            list_new(:ring, 6, width: width), list_new(:back, 6, width: width),
            *items.first(5).map { |item| list_push(:ring, item) },
            *Array.new(3) { list_drop(:ring, from: :front) },
            *items.last(3).map { |item| list_push(:ring, item) },
            save_store_list(:ring, at: at, width: width, index: :slot),
            save_load_list(:back, at: at, count: count, most: 6, width: width, index: :slot),
            set(:seen, list_len(:back)),
            loop_(wait_vblank), console: moved_on)
  end

  private def assert_moves_as_the_interpreter(program)
    interpreters = SaveImage.new
    wanted = Reference.new(save: interpreters).run(program, frames: 2)
    cartridges = SaveImage.new
    played = checked_run.new(save: cartridges).run(program, frames: 2)

    assert_equal wanted.list(:back), played.list(:back)
    assert_equal wanted.list(:ring), played.list(:ring)
    assert_equal interpreters.to_sav, cartridges.to_sav, "save memory"
    played
  end

  def test_a_list_come_round_its_ring_is_written_oldest_first_at_each_width
    %i[byte half word].each do |width|
      played = assert_moves_as_the_interpreter(round_the_ring(width, at: 0x400, count: 5))

      assert_equal 5, played[:seen], "a #{width} list"
    end
  end

  def test_a_run_crossing_eight_kilobytes_of_save_memory_is_whole
    played = assert_moves_as_the_interpreter(round_the_ring(:word, at: 0x1FF6, count: 5))

    assert_equal [4, 5, 6, -7, 8], played.list(:back)
  end

  def test_a_load_of_no_items_empties_the_list
    played = assert_moves_as_the_interpreter(round_the_ring(:half, at: 0x400, count: 0))

    assert_empty played.list(:back)
  end

  def test_a_count_past_the_steps_most_is_held_to_it
    played = assert_moves_as_the_interpreter(round_the_ring(:byte, at: 0x400, count: 99))

    assert_equal 6, played[:seen]
  end
end
