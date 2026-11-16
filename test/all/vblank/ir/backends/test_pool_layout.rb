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

  # A pool naming no layout, or :lists, is kept as lists on every console today.
  def test_a_pool_is_kept_as_lists_where_no_other_layout_fits
    [nil, :lists].each do |layout|
      program = program_with_pool(layout: layout)
      shape = guard_shape(program)
      VBlank::Console::DESCRIPTIONS.each_value do |console|
        assert_equal :lists, PoolLayout.chosen(shape, console, PoolLayout.steps_on(program, shape)).name
      end
    end
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
