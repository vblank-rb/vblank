# frozen_string_literal: true

require "test_helper"

# A TEST THE GAME MAKES BRANCHES ON THE COMPARE ITSELF, with no 0 or 1 worked out on the way. The
# instruction counts are the contract here; the games played at the end of this file are what says
# the shorter code still means the same thing.
class TestConditionBranches < Minitest::Test
  # The code of the game loop's tests: each `if` and everything under its condition. Each game
  # reads a variable first, so the place variables are kept is already in a register, as it is
  # after any earlier statement of a pass. That read is the same node as the test's, so a node is
  # priced by one use of it.
  private def instructions_of_the_test(&game)
    b = Builder.new
    b.instance_eval(&game)
    b.finalize_program
    backend = GBA.new
    backend.lower(b.program)
    tests = b.program.walk.find { |node| node.kind == :loop }.walk.select { |node| node.kind == :if }
    emitted = backend.attribution.emitted
    tests.sum { |test| [test, *test.cond.walk].sum { |node| emitted[node]&.instructions_per_use || 0 } }
  end

  def test_two_variables_are_two_loads_a_compare_and_a_branch
    count = instructions_of_the_test do
      a = var :a, 3
      c = var :c, 5
      seen = 0
      game_loop do
        seen = a
        seen = 1 if a < c
      end
    end

    assert_equal 4, count
  end

  def test_a_small_number_rides_in_the_compare
    count = instructions_of_the_test do
      a = var :a, 3
      seen = 0
      game_loop do
        seen = a
        seen = 1 if a > 0
      end
    end

    assert_equal 3, count
  end

  def test_a_join_of_two_tests_is_two_tests
    count = instructions_of_the_test do
      a = var :a, 3
      c = var :c, 5
      seen = 0
      game_loop do
        seen = a
        seen = 1 if a > 0 && c < 9
      end
    end

    assert_equal 6, count
  end

  # Every test and every operation whose sides moved, walked across the numbers around nought and
  # across a number too big to ride in an instruction, each answer folded into a total.
  def test_a_cartridge_works_out_what_the_interpreter_does
    assert_same_totals do
      a = var :a, -4
      b = var :b, 2
      big = var :big, 70_000
      total = 0
      n = 0
      game_loop do
        bits = 0
        bits |= 1 if a < b
        bits |= 2 if a <= b
        bits |= 4 if a > b
        bits |= 8 if a >= b
        bits |= 16 if a == b
        bits |= 32 if a != b
        bits |= 64 if a > 0
        bits |= 128 if a < -2
        bits |= 256 if big > 69_999
        bits |= 512 if 1 > a
        bits |= 1024 if a * 3 > b + 1
        bits |= 2048 if a > 0 && b > 0
        bits |= 4096 if a > 0 || b > 3
        bits |= 8192 if (a > 0 || b > 3) && big > 5
        total = (total * 3) + bits + (a - b) + (7 - a) + (b - 1) + (a - 70_000) + (big / (b + 9)) + (big % 7)
        total += (big >> 2) + (b << 1) + (3 - (a * b)) + ((a * b) - (b * b))
        a += 1
        b -= 1 if a == 2
        big += 1
        n += 1
        halt if n == 12
      end
    end
  end

  # A join runs both its sides on the interpreter, so a second side that draws a random number
  # must draw it on the cartridge too, or every number after differs.
  def test_a_join_whose_second_side_draws_a_number_still_draws_it
    assert_same_totals do
      seed 7
      a = var :a, 0
      total = 0
      n = 0
      game_loop do
        total += 1 if a > 100 && chance(50)
        total = (total * 3) + rand(1..1000)
        n += 1
        halt if n == 12
      end
    end
  end

  # The arm that follows straight on from a test keeps the place variables and collections are
  # reached from, so what it writes must land where it should.
  def test_each_arm_of_a_test_writes_where_it_should
    assert_same_totals do
      xs = list :xs, capacity: 8
      3.times { xs.push 0 }
      a = var :a, 0
      total = 0
      n = 0
      game_loop do
        xs[0] = 1
        if a > 0
          xs[1] = 2
        else
          xs[2] = 3
        end
        total = (total * 3) + xs[0] + (xs[1] * 5) + (xs[2] * 7)
        a += 1
        n += 1
        halt if n == 3
      end
    end
  end

  # A `repeat` that stops early asks before each pass.
  def test_a_repeat_stops_where_the_interpreter_stops
    assert_same_totals do
      total = 0
      limit = var :limit, 3
      repeat(9, stop_when: total > limit) { total += 1 }
      game_loop { halt }
    end
  end

  # The game ends on its own, so the two are compared at the same moment.
  private def assert_same_totals(&game)
    rom = VBlank.build("TESTS", console: :gba, out: StringIO.new, err: StringIO.new, &game)
    played = Reference.new.run(rom.source_program, frames: 40)
    cartridge = VBlank::Diagnostics::Verifier.new(rom, frames: 40, vars: rom.var_addresses)

    refute_equal 0, played[:total]
    assert_equal played[:total], cartridge.var(:total)
  end
end
