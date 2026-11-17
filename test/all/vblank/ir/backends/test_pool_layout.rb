# frozen_string_literal: true

require "test_helper"

# HOW A CONSOLE KEEPS A POOL (Backends::PoolLayout): which layout a pool is kept in, where its
# slots are in that layout, and the list of every console's own layouts that each console's
# description is held to.
class TestPoolLayout < Minitest::Test
  PoolLayout = VBlank::IR::Backends::PoolLayout

  private def program_with_pool(layout: nil)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :bitmap
      guards = pool :guard, x: 0, hp: 0, capacity: 6, widths: { hp: :byte }, layout: layout
      guards.each { |g| g.x += 1 }
      halt
    end
    b.finalize_program
    b.program
  end

  private def guard_shape(program) = program.pools.find { |shape| shape.name == :guard }

  # Kept as lists, each slot list is an area of its own, a slot as wide as the list: slot 5 of a
  # word list is 20 bytes in, of a byte list 5. The lists are not one stride, so no one index
  # reaches every field.
  def test_lists_keep_each_list_in_an_area_of_its_own
    shape = guard_shape(program_with_pool)
    placement = PoolLayout::ADAPTERS.fetch(:lists).place(shape)
    x = placement.place_of(VBlank::DSL::Pool.field_list(:guard, :x))
    hp = placement.place_of(VBlank::DSL::Pool.field_list(:guard, :hp))

    assert_equal [20, 4, 1], [x.at(5), x.width, x.scale]
    assert_equal [5, 1], [hp.at(5), hp.width]
    assert_equal 24, placement.areas.fetch(x.area)
    assert_nil placement.shared_stride
  end

  # A pool naming :lists is kept as lists on every console; one naming none is kept in the first of
  # its console's layouts that fits it, which for a pool of mixed widths is :tables on the Super
  # Nintendo and :lists everywhere else.
  def test_a_pool_is_kept_as_named_or_in_the_consoles_first_layout_that_fits
    program = program_with_pool(layout: :lists)
    shape = guard_shape(program)
    VBlank::Console::DESCRIPTIONS.each_value do |console|
      assert_equal :lists, PoolLayout.chosen(shape, console, PoolLayout.steps_on(program, shape)).name
    end
    program = program_with_pool
    shape = guard_shape(program)
    steps = PoolLayout.steps_on(program, shape)
    VBlank::Console::DESCRIPTIONS.each_value do |console|
      first = console.pool_layouts.find { |name| PoolLayout::ADAPTERS.fetch(name).fits?(shape, steps) }
      assert_equal first, PoolLayout.chosen(shape, console, steps).name, console.title
    end
    assert_equal :tables, PoolLayout.chosen(shape, VBlank::Console::SUPER_NINTENDO, steps).name
  end

  # A pool whose lists are all one width is kept as lists, since tables would be the same; one
  # that is filled, copied, sorted or saved by the runtime is kept as lists too.
  def test_tables_fit_only_mixed_widths_kept_slot_by_slot
    shape = guard_shape(program_with_pool)
    tables = PoolLayout::ADAPTERS.fetch(:tables)

    assert tables.fits?(shape, %i[list_new list_get list_set])
    refute tables.fits?(shape, %i[list_new list_get list_fill])
    refute tables.fits?(shape.with(slot_lists: shape.slot_lists.transform_values { :byte }, link_lists: []), %i[list_get])
  end

  # Tables put every slot list at the pool's widest slot; records put a thing's values side by
  # side, widest first, in a record rounded up to a power of two.
  def test_tables_and_records_share_one_stride
    shape = guard_shape(program_with_pool)
    tables = PoolLayout::ADAPTERS.fetch(:tables).place(shape)
    records = PoolLayout::ADAPTERS.fetch(:records).place(shape)
    x = VBlank::DSL::Pool.field_list(:guard, :x)

    assert_equal 4, tables.shared_stride
    assert_equal [20, 4], [tables.place_of(x).at(5), tables.place_of(x).width]
    assert_equal 0, records.shared_stride % 4
    assert_equal 0, records.place_of(x).offset
    assert_equal 1, records.areas.size
  end

  # The builds for a computer (desktop, web, Ruby) keep every pool as lists, whatever layout the game
  # names for the console they are made as (Computer::Lowering.pool_layout).
  def test_the_builds_for_a_computer_keep_every_pool_as_lists_whatever_layout_it_names
    shape = guard_shape(program_with_pool)
    [nil, :lists, :tables, :records].each do |layout|
      kept = VBlank::IR::Backends::Computer::Lowering.pool_layout(shape.with(layout: layout))

      assert_equal :lists, kept.name, "a pool naming #{layout.inspect}"
    end
  end

  # A link is kept as the slot times the stride in two bytes, so the next thing's place is read
  # straight into an index; NONE stays NONE.
  def test_tables_keep_links_scaled
    shape = guard_shape(program_with_pool)
    links = PoolLayout::ADAPTERS.fetch(:tables).place(shape).place_of(VBlank::DSL::Pool.next_list(:guard))

    assert_equal [4, 2, 4], [links.scale, links.width, links.stride]
  end

  # The steps a program takes on a pool's lists, which a layout reads to know whether it can keep it.
  def test_the_steps_on_a_pools_lists_are_found
    program = program_with_pool
    steps = PoolLayout.steps_on(program, guard_shape(program))

    assert_includes steps, :list_get
    assert_includes steps, :list_set
  end

  # Every layout a console names beyond :lists is in the list of consoles' own layouts with its
  # reason, and every entry there is one its console names; every layout named has an adapter.
  def test_every_consoles_own_layouts_are_listed_with_their_reason
    VBlank::Console::DESCRIPTIONS.each do |name, console|
      own = console.pool_layouts - [:lists]
      assert_equal own.sort, PoolLayout::OWN_LAYOUTS.fetch(name, {}).keys.sort, "#{name}'s own pool layouts"
      console.pool_layouts.each { |layout| assert PoolLayout::ADAPTERS.key?(layout), "#{name} names #{layout}" }
      assert_includes console.pool_layouts, :lists
    end
    PoolLayout::OWN_LAYOUTS.each_value do |layouts|
      layouts.each_value { |reason| refute_empty reason }
    end
  end

  # A walk stepped a layout's own way leaves the thing it is on and the next in their variables.
  def test_a_walk_leaves_its_numbers_in_the_trees_variables
    walk = program_with_pool.walk.filter_map { |node| node.pool_walk if node.kind == :repeat }.first

    assert_equal [walk.at, walk.ahead], PoolLayout.walk_results(walk)
  end
end
