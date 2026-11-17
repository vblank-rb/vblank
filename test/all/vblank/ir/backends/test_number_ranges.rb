# frozen_string_literal: true

require "test_helper"

# WHAT RANGE A NUMBER STAYS IN (Backends::NumberRanges), held to what the game does: a game whose
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
    assert_equal NumberRanges::HALF, ranges.variable(:masked)
    refute_includes ranges.variables_within(NumberRanges::BYTE), :masked
  end

  def test_a_count_that_climbs_without_a_bound_is_not_proven
    ranges = NumberRanges.new(built)

    assert_nil ranges.variable(:climbing)
    assert_nil ranges.variable(:turned_round)
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

  private def built = counting_game.program(console: VBlank::Testing.console)

  private def counting_game
    VBlank.game("NUMBER RANGES", consoles: %i[gba gbc snes genesis ps1]) do
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
