# frozen_string_literal: true

require "test_helper"

# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
#
# Which of the Advance's memories its cartridge keeps a pool in, and a pool drawn by the
# cartridge in the emulator, are in test/lowering/gba/vblank/builder/test_pool_cartridge.rb.
class TestPool < Minitest::Test
  GREEN = Color.resolve(:green)
  BLACK = 0

  # The variable a pool keeps how many of its instances are live in.
  private def live_count_of(pool) = VBlank::DSL::Pool.count_var(pool)

  # spawn several instances with distinct fields; each draws every live one at its own
  # (x, y). Proves spawn, each, per-instance field reads, and that fields stay paired
  # (each instance draws at ITS own x AND y, never a crossed pair).
  def test_spawn_and_each_draw_each_live_instance_at_its_own_fields
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 8
      bullets.spawn x: 10, y: 12
      bullets.spawn x: 40, y: 30
      bullets.spawn x: 80, y: 50
      game_loop do
        wait_vblank
        clear_screen :black
        bullets.each { |bl| draw_rect_at bl.x, bl.y, 2, 2, :green }
      end
    end
    b.finalize_program
    i = game_player.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 12), "first instance drawn at its own (x, y)"
    assert_equal GREEN, i.screen.pixel(40, 30)
    assert_equal GREEN, i.screen.pixel(80, 50)
    assert_equal BLACK, i.screen.pixel(120, 100), "nowhere else"
    assert_equal 3, i[live_count_of(:bullet)], "three instances are live"
  end

  # A row handle's field is a mutable Value: b.y += 1 moves it, b.y.clamp! pins it (the
  # read-modify-write path through a scratch var). The instance settles at the clamp.
  def test_a_field_is_mutable_per_instance
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      movers = pool :mover, x: 0, y: 0, capacity: 4
      movers.spawn x: 50, y: 10
      game_loop do
        wait_vblank
        clear_screen :black
        movers.each do |m|
          m.y += 2
          m.y.clamp! 0, 80
          draw_rect_at m.x, m.y, 2, 2, :green
        end
      end
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 45) # the mover needs ~35 frames to reach its clamp

    assert_equal GREEN, i.screen.pixel(50, 80), "it moved down and settled at the clamp"
    assert_equal BLACK, i.screen.pixel(50, 10), "it left its start"
  end

  # remove retires the current instance during each: it stops drawing next frame and
  # the live count drops. Other instances are untouched.
  def test_remove_retires_one_instance
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      things = pool :thing, x: 0, y: 0, capacity: 8
      things.spawn x: 10, y: 40
      things.spawn x: 20, y: 40
      things.spawn x: 30, y: 40
      game_loop do
        wait_vblank
        clear_screen :black
        things.each do |t|
          t.remove if t.x == 20
          draw_rect_at t.x, t.y, 2, 2, :green
        end
      end
    end
    b.finalize_program
    i = game_player.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 40), "the others remain"
    assert_equal GREEN, i.screen.pixel(30, 40)
    assert_equal BLACK, i.screen.pixel(20, 40), "the removed one is gone"
    assert_equal 2, i[live_count_of(:thing)], "the live count dropped by one"
  end

  # spawn on a full pool is a safe no-op: the count never exceeds capacity and nothing
  # is corrupted.
  def test_spawn_on_a_full_pool_is_a_safe_no_op
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      p = pool :p, x: 0, capacity: 3
      5.times { p.spawn x: 1 } # two more than it can hold
      halt
    end
    b.finalize_program
    i = game_player.run(b.program)

    assert_equal 3, i[live_count_of(:p)], "the pool filled to capacity and the extra spawns were dropped"
  end

  # b.index hands back an instance's own slot as a Value. Save it in a variable while
  # comparing across a pool (an each), then reach that exact instance's fields again
  # after the loop with field_ref — proving the slot round-trips to the right instance,
  # not just any one of them.
  def test_index_remembers_which_instance_won_a_comparison
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      found = -1
      things = pool :thing, x: 0, y: 0, tag: 0, capacity: 8
      things.spawn x: 10, y: 40, tag: 1
      things.spawn x: 20, y: 40, tag: 2
      things.spawn x: 30, y: 40, tag: 3
      game_loop do
        wait_vblank
        clear_screen :black
        things.each { |t| found = t.index if t.tag == 2 }
        draw_rect_at things.field_ref(:x, found), 100, 2, 2, :green
      end
    end
    b.finalize_program
    i = game_player.run(b.program)

    assert_equal GREEN, i.screen.pixel(20, 100), "index led back to the instance tagged 2 (x=20)"
    assert_equal BLACK, i.screen.pixel(10, 100), "not the instance tagged 1"
    assert_equal BLACK, i.screen.pixel(30, 100), "not the instance tagged 3"
  end

  # Fields kept in half words, each pair tested for how far apart it is: just inside and just
  # outside on each side, and the two ends of a half word, 65535 apart either way, whose 16-bit
  # difference alone would look near. Each pair's test sets its own bit.
  def test_half_word_fields_tested_for_how_far_apart
    b = Builder.new
    b.instance_eval do
      near = 0
      pairs = pool :pair, a: 0, b: 0, bit: 0, capacity: 8, widths: { a: :half, b: :half }
      [[20, 5, 1], [21, 5, 2], [5, 20, 4], [5, 21, 8], [32_767, -32_768, 16], [-32_768, 32_767, 32],
       [-32_768, -32_768, 64], [32_767, 32_752, 128]].each { |a, b_, bit| pairs.spawn(a: a, b: b_, bit: bit) }
      game_loop do
        near = 0
        pairs.each do |pair|
          near += pair.bit if (pair.a - pair.b).abs < 16
          near += pair.bit * 256 if (pair.a + pair.b).abs <= 1
        end
      end
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 2)

    assert_equal 1 + 4 + 64 + 128 + (32 * 256) + (16 * 256), i[:near]
  end

  # --- what a pool is, for a console that keeps one its own way ---

  private def pool_program(console: :gba, &game)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval(&game)
    b.finalize_program
    b.program
  end

  # The program says what each pool is: its fields at the widths the game declared, its own lists,
  # its variables, and the layout it asked for.
  def test_the_program_carries_each_pool_as_declared
    program = pool_program do
      screen :bitmap
      pool :guard, x: 0, hp: 0, capacity: 6, widths: { hp: :byte }, layout: :lists
      halt
    end
    shape = program.pools.find { |each| each.name == :guard }

    assert_equal [6, :lists], [shape.capacity, shape.layout]
    assert_equal({ x: :word, hp: :byte }, shape.fields.to_h { |field| [field.name, field.width] })
    assert_equal :byte, shape.width_of(VBlank::DSL::Pool.active_list(:guard))
    assert_equal VBlank::DSL::Pool.head_var(:guard), shape.vars.fetch(:head)
  end

  # Each walk's loop says it is one: the thing it is on, the next, the last, and the links it
  # follows, the other way round for a walk newest first.
  def test_each_walk_is_marked_on_its_loop
    program = pool_program do
      screen :bitmap
      things = pool :thing, x: 0, capacity: 4
      things.each { |t| t.x += 1 }
      things.each(newest_first: true) { |t| t.x -= 1 }
      halt
    end
    walks = program.walk.filter_map { |node| node.pool_walk if node.kind == :repeat }

    assert_equal [VBlank::DSL::Pool.next_list(:thing), VBlank::DSL::Pool.prev_list(:thing)], walks.map(&:links)
    assert(walks.all? { |walk| walk.pool == :thing && walk.step_statements == 2 })
  end

  # A layout a console has no way to keep a pool in is refused before anything is built, naming
  # the console and the layouts it has; a word that is no layout at all is refused on any.
  def test_a_layout_the_console_lacks_is_refused_in_plain_words
    others = %i[tables records]
    VBlank::Console::DESCRIPTIONS.each do |name, description|
      (others - description.pool_layouts).each do |layout|
        error = assert_raises(ArgumentError) { pool_program(console: name) { pool :guard, x: 0, capacity: 4, layout: layout } }
        assert_includes error.message, "keeps a pool only as"
        assert_includes error.message, description.title
      end
    end
    error = assert_raises(ArgumentError) { pool_program { pool :guard, x: 0, capacity: 4, layout: :rows } }
    assert_includes error.message, "A pool layout is"
  end

  # --- baked guardrails (build-time, friendly errors) ---

  # A POOL TOO BIG TO SHARE THE QUICK MEMORY. The console has 32K of quick memory, which the
  # game's hot code lives in too, and 256K of roomier memory. A pool over the ceiling is kept
  # in the roomier one, where it fits: it is refused only when the game insists on the quick
  # one, and a capacity too big for both memories is the whole-program check's to refuse.

  # The lists a pool was built from, as the program declares them.
  private def lists_of(program) = program.walk.select { |node| node.kind == :list_new }

  # The most a pool can be is the console's: a Game Boy Color has 8K of work memory in view, so
  # 1,000 things of four whole-number fields, 16,000 bytes, are refused for it by name.
  def test_a_pool_bigger_than_the_colors_memory_is_refused_naming_its_size
    message = assert_raises(ArgumentError) do
      Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc)).instance_eval do
        pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000
      end
    end.message

    assert_match(/pool :crowd/, message)
    assert_match(/Game Boy Color holds 8KB/, message)
  end

  def test_an_insane_capacity_is_a_friendly_error
    assert_match(/pool :swarm/, too_big { pool :swarm, x: 0, y: 0, capacity: 99_999 })
  end

  # Two pools that each fit the roomier memory and do not fit it together: 135,000 bytes
  # apiece. The build's checks refuse them before they are laid out, naming them as the pools the
  # game declared, not as the lists the framework made them from.
  def test_pools_that_fill_the_roomier_memory_between_them_are_named_as_pools
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("TWO", console: :gba, out: StringIO.new, err: err) do
        screen :bitmap
        pool :left, x: 0, y: 0, vx: 0, vy: 0, capacity: 5400
        pool :right, x: 0, y: 0, vx: 0, vy: 0, capacity: 5400
        game_loop {}
      end
    end

    assert_match(/pool :(left|right)/, err.string)
    assert_match(/`fast: false`/, err.string, "the finding for collections kept out of the quick memory")
    refute_match(/__pool/, err.string, "no name of the framework's own")
  end

  # A pool that draws its instances spends a sprite on each, and the console draws 128: that
  # is what stops a big one that would fit in memory. The words are the sprite check's own
  # and are tested with it; what is pinned here is that such a pool does not build.
  def test_a_big_pool_that_draws_its_instances_does_not_build
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("FLOCK", console: :gba, out: StringIO.new, err: err) do
        screen :tiled
        image(:dot, "#" => :white) { "########\n" * 8 }
        pool :flock, x: 0, y: 0, capacity: 1000, image: :dot, fast: false
        game_loop {}
      end
    end

    assert_match(/pool :flock/, err.string, "the pool is named as what takes the sprites")
  end

  # THE COUNT IS OF THE POOL AS IT IS BUILT. A pool is a list per field and a few of its
  # own, each exactly `capacity` slots long and each as wide as it was declared — so that is
  # what is counted. Counting it bigger refuses a pool that fits. These insist on the quick
  # memory, which is what holds a pool to the ceiling.

  private def too_big(&game) = assert_raises(ArgumentError) { Builder.new.instance_eval(&game) }.message

  # How many KB the error says the pool needs.
  private def kilobytes_said(message) = message[/about (\d+)KB/, 1].to_i

  # A real game's cast: 145 guards of thirteen fields, ten of them narrowed. By its declared
  # widths that is 34 bytes a slot, under five kilobytes.
  def test_a_pool_of_narrow_fields_is_counted_at_the_widths_it_declared
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      pool :guard, a: 0, b: 0, c: 0, d: 0, e: 0, f: 0, g: 0, h: 0, i: 0, j: 0, k: 0, l: 0, m: 0,
                   capacity: 145,
                   widths: { a: :byte, b: :byte, c: :byte, d: :byte, e: :byte, f: :byte, g: :byte,
                             h: :half, i: :half, j: :half }
      game_loop {}
    end
    builder.finalize_program

    assert_operator GBA.new.lower(builder.program).bytesize, :>, 0, "and it builds"
  end

  # 1000 slots of four word fields: 16 bytes of fields, a byte saying whether the slot is
  # live, and four slot numbers of two bytes each (the free stack and the order they came in).
  def test_a_pool_that_is_too_big_says_the_size_it_would_be_built_at
    message = too_big { pool :swarm, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000, fast: true }

    assert_equal (1000 * (16 + 1 + (4 * 2))) / 1024, kilobytes_said(message)
  end

  # A pool with pictures keeps more a slot: which frame each instance is on, and where and
  # what each is in the order they are drawn. Those are in the count as well.
  def test_a_pool_with_pictures_is_counted_with_the_lists_its_pictures_need
    plain = too_big { pool :mote, x: 0, y: 0, capacity: 5000, fast: true }
    drawn = too_big do
      screen :tiled
      image :one, width: 8, height: 8, data: Array.new(64, :red)
      image :two, width: 8, height: 8, data: Array.new(64, :green)
      pool :mote, x: 0, y: 0, capacity: 5000, frames: %i[one two], rate: 4, fast: true
    end

    assert_operator kilobytes_said(drawn), :>, kilobytes_said(plain)
  end
end
