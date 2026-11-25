# frozen_string_literal: true

require "test_helper"

# What range a number stays in (Backends::NumberRanges), held to what the game does: a game whose
# variables the proof says stay in a byte or two is played on every run, and each of those
# variables is read after every pass and must be inside what was proven. A proof that claims too
# much fails here on the interpreter itself, before any console narrows a number on its word.
class TestNumberRanges < Minitest::Test
  NumberRanges = VBlank::IR::Backends::NumberRanges

  PASSES = 300

  def test_proven_variables_stay_in_their_range_as_the_game_plays
    program = built
    ranges = NumberRanges.new(program)
    proven = %i[masked wrapped clamped copied stepped filled entry shifted leftover]
    proven.each { |name| refute_nil ranges.variable(name), "#{name} is proven to stay small" }

    seen = Hash.new { |all, name| all[name] = [] }
    player = game_player
    player.each_vblank { proven.each { |name| seen[name] << player[name] } }
    player.run(program, frames: PASSES)

    proven.each do |name|
      range = ranges.variable(name)
      outside = seen[name].reject { |number| range.cover?(number) }
      assert_empty outside, "#{name} was proven within #{range}"
    end
  end

  def test_a_variable_in_a_byte_is_in_two_as_well
    ranges = NumberRanges.new(built)

    assert_equal NumberRanges::BYTE, ranges.variable(:copied)
    assert_includes ranges.variables_within(NumberRanges::HALF), :copied
    assert_equal 0..1023, ranges.variable(:masked)
    refute_includes ranges.variables_within(NumberRanges::BYTE), :masked
  end

  def test_a_count_that_climbs_without_a_bound_is_not_proven_and_one_turned_round_is
    ranges = NumberRanges.new(built)

    assert_nil ranges.variable(:climbing)
    assert_equal(-1..1, ranges.variable(:turned_round))
  end

  def test_a_value_has_the_range_of_what_it_is_made_of
    program = built
    ranges = NumberRanges.new(program)
    build = VBlank::IR::Build

    assert_equal(-128..127, ranges.range_of_value(build.list_get(:bytes, build.var_ref(:masked))))
    assert_equal(0..1, ranges.range_of_value(build.binop(:<, build.var_ref(:climbing), build.int(3))))
    assert_equal(-8..7, ranges.range_of_value(build.binop(:>>, build.list_get(:halves, build.int(0)), build.int(12))))
    assert_nil ranges.range_of_value(build.binop(:+, build.var_ref(:climbing), build.int(1)))
    # 0xFFFF_FFFD divides as -3 (Int32.mod), so the remainder takes that sign.
    assert_equal(-2..0, ranges.range_of_value(build.binop(:%, build.var_ref(:masked), build.int(0xFFFF_FFFD))))
    assert_equal(0..9, ranges.range_of_value(build.var_ref(:climbing)) { |name| (0..9 if name == :climbing) })
  end

  # The edges of 16 BITS: variables proven to stay in two bytes, which a console may keep in two,
  # driven to 32767 and -32768 and read on every pass, and whole numbers one past each made of them.
  # Every run plays it, each console's build checked against the interpreter after every pass.
  def test_numbers_at_the_edges_of_16_bits_keep_the_interpreters_answers
    program = edges_game.program(console: VBlank::Testing.console)
    ranges = NumberRanges.new(program)
    assert_equal [0..32_767, -32_768..0, -32_768..0], %i[up down copied_down].map { |name| ranges.variable(name) }
    assert_equal 0..32_768, ranges.variable(:past)
    refute_includes ranges.variables_within(NumberRanges::HALF), :past

    player = game_player
    player.run(program, frames: 8)

    assert_equal [32_767, -32_768, -32_768, 32_768, -32_769, 7], %i[up down copied_down past below read].map { |name| player[name] }
    assert_operator player[:hits], :>, 0
  end

  # A difference of two numbers each kept in 0..2047 is about -2047..2047, its real range, not only
  # "two bytes if both are". A range still growing is taken to the next bit, so -2048 at most.
  def test_a_difference_has_the_real_range_of_its_sides
    program = VBlank.game("DIFFERENCE", consoles: %i[gba gbc snes genesis ps1 dos]) do
      screen :bitmap
      x = 0
      y = 0
      d = 0
      game_loop do
        x = (x + 3) & 2047
        y = (y + x) & 2047
        d = x - y
      end
    end.program(console: VBlank::Testing.console)

    range = NumberRanges.new(program).variable(:d)

    assert NumberRanges.inside?(-2047..2047, range), "the difference reaches both ends"
    assert NumberRanges.inside?(range, -2048..2047), "#{range} is no wider than the next bit takes it"
  end

  # A pool's fields at the edges of 16 BITS: fields a console may keep in two bytes, spawned from a
  # variable, driven to 32767 and -32768, written by one thing to another in a walk, and freed and
  # spawned again; and whole numbers one past each made of them. Every run plays it.
  def test_pool_fields_at_the_edges_of_16_bits_keep_the_interpreters_answers
    program = pool_edges_game.program(console: VBlank::Testing.console)
    widths = NumberRanges.new(program).list_widths
    x_list, y_list = %i[x y].map { |field| VBlank::DSL::Pool.field_list(:thing, field) }
    assert_equal({ x_list => :half, y_list => :half }, widths.slice(x_list, y_list))

    player = game_player
    player.run(program, frames: 10)

    assert_equal [[32_767], [-32_768]], %i[x y].map { |field| player.pool(:thing, field).compact.uniq }
    assert_equal [32_768, -32_769], %i[past below].map { |name| player[name] }
  end

  private def pool_edges_game
    VBlank.game("FIELD EDGES", consoles: %i[gba gbc snes genesis ps1 dos]) do
      screen :bitmap
      things = pool :thing, x: 0, y: 0, capacity: 4
      start = 0
      pass = 0
      past = 0
      below = 0
      game_loop do
        pass += 1
        start = (start + 5) & 63
        things.spawn(x: start, y: -3) if pass < 4 || pass == 7
        things.each do |t|
          t.x = (t.x + 9000).clamp(-32_768, 32_767)
          t.y = (t.y - 9000).clamp(-32_768, 32_767)
          t.remove if pass == 6 && t.index == 0
        end
        things.each { |t| things.each { |other| other.y = t.y if other.index != t.index } }
        things.each do |t|
          past = t.x + 1
          below = t.y - 1
        end
      end
    end
  end

  private def edges_game
    VBlank.game("HALF EDGES", consoles: %i[gba gbc snes genesis ps1 dos]) do
      screen :bitmap
      items = list :items, capacity: 8, full_of: 7
      up = 0
      down = 0
      copied_down = 0
      step = 0
      past = 0
      below = 0
      hits = 0
      read = 0
      game_loop do
        up = (up + 9000).clamp(-32_768, 32_767)
        down = (down - 9000).clamp(-32_768, 32_767)
        copied_down = down
        past = up + 1
        below = copied_down - 1
        hits += 1 if up > 32_766 && down < -32_767
        step = (step + 3) & 7
        read = items[step]
      end
    end
  end

  # A slot keeps its low bits from the start too: a list of bytes filled with 200 holds -56, so
  # 100 taken from an item is -156, which no byte holds.
  def test_a_list_filled_past_its_slot_starts_with_what_the_slot_keeps
    build = VBlank::IR::Build
    program = build.program(build.list_new(:xs, 4, width: :byte, full_of: 200),
                            build.set(:v, build.binop(:-, build.list_get(:xs, 0), 100)), build.wait_vblank, build.halt)

    assert_equal(-56..-56, NumberRanges.new(program).list(:xs))
    player = game_player
    player.run(program, frames: 2)

    assert_equal(-156, player[:v])
  end

  # A list declared twice, filled differently each time, holds what either filled it with.
  def test_a_list_declared_twice_holds_what_each_declaration_fills_it_with
    build = VBlank::IR::Build
    program = build.program(build.list_new(:hp, 4, full_of: 1), build.set(:low, build.list_get(:hp, 0)),
                            build.list_new(:hp, 4, full_of: 100_000), build.set(:high, build.list_get(:hp, 0)),
                            build.wait_vblank, build.halt)
    ranges = NumberRanges.new(program)

    refute_includes ranges.list_widths.keys, :hp
    assert NumberRanges.inside?(1..100_000, ranges.list(:hp)), "#{ranges.list(:hp)} holds both fills"
    player = game_player
    player.run(program, frames: 2)

    assert_equal [1, 100_000], %i[low high].map { |name| player[name] }
  end

  # A place in 256THS OF A PIXEL, kept with `& 0xFFFF`: a list holding 0..65535, which two bytes
  # hold with no sign though no signed slot does. Every run plays it across 32767, 32768 and 65535,
  # read back as the interpreter reads it.
  def test_a_list_kept_in_0_to_65535_reads_back_unsigned
    program = unsigned_places_game.program(console: VBlank::Testing.console)
    ranges = NumberRanges.new(program)
    place = VBlank::DSL::Pool.field_list(:walker, :place)

    assert_includes ranges.unsigned_half_lists, place
    refute_includes ranges.list_widths.keys, place
    player = game_player
    seen = []
    player.each_vblank { seen << player.pool(:walker, :place).compact }
    player.run(program, frames: 40)

    all = seen.flatten
    assert_includes all, 32_768
    assert_includes all, 65_535
    assert all.all? { |number| number.between?(0, 65_535) }, "every place reads back from 0 to 65535"
    assert_equal 65_536, player[:past]
  end

  private def unsigned_places_game
    VBlank.game("UNSIGNED PLACES", consoles: %i[gba gbc snes genesis ps1 dos]) do
      screen :bitmap
      walkers = pool :walker, place: 0, capacity: 4
      walkers.spawn(place: 32_765)
      walkers.spawn(place: 65_530)
      past = 0
      game_loop do
        walkers.each do |w|
          w.place = (w.place + 1) & 0xFFFF
          past = w.place + 1 if w.place == 65_535
        end
      end
    end
  end

  private def built = counting_game.program(console: VBlank::Testing.console)

  private def counting_game
    VBlank.game("NUMBER RANGES", consoles: %i[gba gbc snes genesis ps1 dos]) do
      screen :bitmap
      bytes = list :bytes, capacity: 8, width: :byte, full_of: -3
      halves = list :halves, capacity: 8, width: :half, full_of: 0
      filling = list :filling, capacity: 20, full_of: 0
      deltas = table :deltas, [-7, 3, 90, -100], width: :byte
      climbing = 0
      turned_round = 1
      masked = 0
      wrapped = 0
      clamped = 0
      copied = 0
      stepped = 0
      filled = 0
      entry = 0
      shifted = 0
      leftover = 0
      game_loop do
        climbing += 1
        turned_round = -turned_round
        masked = (masked + 300) & 1023
        wrapped = climbing % 200
        clamped = climbing.clamp(-5, 1000)
        copied = bytes[masked & 7]
        bytes[masked & 7] = climbing
        halves[masked & 7] = climbing * 97
        stepped = 0
        while stepped < 40
          leftover = stepped
          stepped += 1
        end
        filled = 0
        repeat(20) do
          filling[filled] = climbing
          filled += 1
        end
        entry = deltas[climbing & 3] + bytes[1]
        shifted = halves[climbing & 7] >> 6
        leftover = ((climbing * 7) % 13) - 6
      end
    end
  end
end
