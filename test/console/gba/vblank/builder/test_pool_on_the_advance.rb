# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_pool.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
#
# The same crowd drawn by the Advance's cartridge in the emulator is in
# test/lowering/gba/vblank/builder/test_pool_on_the_advance_cartridge.rb.

# The game both files play.
module PoolOnTheAdvanceGames
  # A pool of a thousand, too big for the quick memory, that draws the first and the last spawned.
  private def crowd_of_a_thousand
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      crowd = pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000
      # Each one tagged with the order it was spawned in, so the first and the last can be
      # picked out whatever slots they landed in.
      repeat(1000) { |i| crowd.spawn x: i % 200, y: 20, vx: i }
      crowd.each { |one| draw_rect_at one.x, one.y, 4, 4, :green if one.vx == 0 || one.vx == 999 }
      game_loop {}
    end
    b.finalize_program
    b.program
  end
end

class TestPoolOnTheAdvance < Minitest::Test
  include PoolOnTheAdvanceGames

  GREEN = Color.resolve(:green)

  # The same from the roomier memory: a pool too big for the quick one is spawned into,
  # walked and read there like any other, the last of its thousand slots included.
  def test_a_pool_in_the_roomier_memory_draws_on_the_console
    i = game_player.run(crowd_of_a_thousand, frames: 2)
    assert_equal [GREEN, GREEN], [i.screen.pixel(1, 21), i.screen.pixel(200, 21)], "the interpreter draws both"
  end

  private def too_big(&game) = assert_raises(ArgumentError) { Builder.new.instance_eval(&game) }.message

  # How many KB the error says the pool needs.
  private def kilobytes_said(message) = message[/about (\d+)KB/, 1].to_i

  # The lists a pool was built from, as the program declares them.
  private def lists_of(program) = program.walk.select { |node| node.kind == :list_new }

  def test_a_pool_over_the_ceiling_that_insists_on_the_quick_memory_is_refused
    message = too_big { pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000, fast: true }

    assert_match(/pool :crowd/, message)
    assert_includes message, VBlank::Messages::PlainWords::QUICK_MEMORY, "it names the memory the game asked for"
    assert_match(/remove `fast: true`/, message, "and the way out that keeps the capacity")
  end

  # A POOL NO MEMORY CAN HOLD is refused at its own line, by name. The roomier memory is
  # 256K and a pool over the ceiling is kept there whole, so one bigger than that fits
  # nowhere — whatever else the game declares, and whether or not it said `fast: false`.
  # 10,800 things of 25 bytes are 270,000 bytes: more than the roomier memory, and less than
  # the two memories added together, which is all the whole-program check asks about.
  def test_a_pool_bigger_than_the_roomier_memory_is_refused_by_name
    [{}, { fast: false }].each do |words|
      message = too_big { pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 10_800, **words }

      assert_match(/pool :crowd/, message)
      assert_match(/largest memory of a Game Boy Advance holds 256KB/, message, "it names the memory")
      assert_equal 270_000 / 1024, kilobytes_said(message)
    end
  end

  # None of a pool's lists is a queue the game shifts, so none is rounded up to a power of
  # two: 513 slots are 513 slots, not 1024.
  def test_a_capacity_is_counted_as_given_and_not_rounded_up
    motes = Builder.new.instance_eval { pool :mote, x: 0, y: 0, vx: 0, vy: 0, capacity: 513 }

    assert_equal 513, motes.capacity
  end

  def test_many_slots_of_byte_fields_fit_where_word_fields_would_not
    fields = { a: 0, b: 0, c: 0, d: 0, e: 0, f: 0 }
    narrow = fields.transform_values { :byte }

    Builder.new.instance_eval { pool :spark, capacity: 600, widths: narrow, fast: true, **fields }
    assert_match(/spark/, too_big { pool :spark, capacity: 600, fast: true, **fields },
                 "the same pool at a word a field is four times the size")
  end

  # WHAT IS COUNTED IS WHAT IS BUILT, to the byte. Seven byte fields, the byte that says a
  # slot is live and four slot numbers of two bytes are sixteen bytes a slot, so 1024 slots
  # are the ceiling exactly — read here off the lists the build was really handed.
  def test_a_pool_exactly_at_the_ceiling_is_built_and_one_slot_more_is_refused
    fields = %i[a b c d e f g].to_h { |field| [field, 0] }
    narrow = fields.transform_values { :byte }
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      pool :mote, capacity: 1024, widths: narrow, fast: true, **fields
      game_loop {}
    end
    builder.finalize_program
    built = lists_of(builder.program).sum { |node| node.capacity * VBlank::IR::Build::ELEMENT_BYTES.fetch(node.width) }

    assert_equal VBlank::Builder::Composition::POOL_MAX_QUICK_BYTES, built
    assert_match(/mote/, too_big { pool :mote, capacity: 1025, widths: narrow, fast: true, **fields })
  end
end
