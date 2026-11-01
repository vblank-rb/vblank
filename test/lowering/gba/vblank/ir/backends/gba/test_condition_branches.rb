# frozen_string_literal: true

require "test_helper"

# A TEST THE GAME MAKES BRANCHES ON THE COMPARE ITSELF, with no 0 or 1 worked out on the way. The
# instruction counts are the contract here; the games played further down are what says the
# shorter code still means the same thing.
class TestConditionBranches < Minitest::Test
  # Every game's first statement reads a variable, so the place variables are kept is already in
  # a register, as it is after any earlier statement of a pass, and `seen = 1` is the one body.
  def test_two_variables_are_two_loads_a_compare_and_a_branch
    assert_equal 4, instructions_in_tests(binop(:<, var_ref(:a), var_ref(:c)))
  end

  def test_a_small_number_rides_in_the_compare
    assert_equal 3, instructions_in_tests(binop(:>, var_ref(:a), int(0)))
  end

  def test_a_join_of_two_tests_is_two_tests
    join = binop(:and, binop(:>, var_ref(:a), int(0)), binop(:<, var_ref(:c), int(9)))

    assert_equal 6, instructions_in_tests(join)
  end

  def test_a_test_turned_round_is_the_same_test
    turned = binop(:==, binop(:<, var_ref(:a), var_ref(:c)), int(0))

    assert_equal 4, instructions_in_tests(turned)
  end

  def test_a_join_turned_round_makes_no_number
    join = binop(:or, binop(:>, var_ref(:a), int(0)), binop(:<, var_ref(:c), int(9)))

    assert_equal 6, instructions_in_tests(binop(:==, join, int(0)))
  end

  def test_a_chance_on_the_right_of_a_join_can_go_unread
    assert VBlank::IR::Backends::GBA::Expressions.changes_nothing?(chance(var_ref(:a), 50))
  end

  # An index out of range stops the game, and the interpreter works out both sides of a join.
  def test_a_list_read_on_the_right_of_a_join_is_never_skipped
    refute VBlank::IR::Backends::GBA::Expressions.changes_nothing?(binop(:>, list_get(:xs, int(5)), int(0)))
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

  # `&` and `|` on two tests are joins. Each shape is here both ways round, since a join takes one
  # path when the branch wants the answer one side settles and another when it does not.
  def test_every_shape_of_join_agrees_with_the_interpreter
    assert_same_totals do
      a = var :a, -3
      b = var :b, 3
      total = 0
      n = 0
      game_loop do
        bits = 0
        bits |= 1 if (a > 0) & (b > 0)
        bits |= 2 if (a > 0) | (b > 2)
        bits |= 4 if !((a > 0) & (b > 0))
        bits |= 8 if !((a > 0) | (b > 2))
        bits |= 16 if ((a > 0) & (b > 0)) | (a < -2)
        bits |= 32 if ((a > 0) | (b > 2)) & (a < 1)
        bits |= 64 unless (a > 0) | (b > 2)
        bits |= 128 unless a < b
        total = (total * 3) + bits + 1
        a += 1
        b -= 1
        n += 1
        halt if n == 12
      end
    end
  end

  # A `while` stops on its test turned round, and a `repeat` asks before each pass, so a join here
  # branches away when it holds rather than when it does not.
  def test_a_loop_stops_where_the_interpreter_stops
    assert_same_totals do
      total = 0
      limit = var :limit, 3
      other = var :other, 100
      repeat(9, stop_when: total > limit) { total += 1 }
      repeat(9, stop_when: (total > 7) | (other < 0)) { total += 1 }
      repeat(9, stop_when: (total > 2) & (other > 0)) { total += 10 }
      total += 1 while total < 40
      game_loop { halt }
    end
  end

  # A chance's number is drawn by a statement before the test, so every number after it agrees
  # whether or not the join reads it.
  def test_a_chance_in_a_join_agrees_with_the_interpreter
    assert_same_totals do
      seed 7
      a = var :a, 0
      total = 0
      n = 0
      game_loop do
        total += 1 if (a > 100) & chance(50)
        total += 2 if (a < 100) | chance(50)
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

  private def int(value) = VBlank::IR::Build.int(value)
  private def var_ref(name) = VBlank::IR::Build.var_ref(name)
  private def binop(op, lhs, rhs) = VBlank::IR::Build.binop(op, lhs, rhs)
  private def chance(draw, percent) = VBlank::IR::Build.chance(draw, percent)
  private def list_get(name, index) = VBlank::IR::Build.list_get(name, index)

  # The code of a loop's one `if` on +test+ and everything under it. The read before it is the same
  # kind of node, so a node is priced by one use of it.
  private def instructions_in_tests(test)
    build = VBlank::IR::Build
    tested = build.if_(test, build.set(:seen, 1))
    program = build.program(build.screen(:bitmap), build.set(:a, 3), build.set(:c, 5), build.set(:seen, 0),
                            build.loop_(build.wait_vblank, build.copy(:seen, :a), tested))
    backend = GBA.new
    backend.lower(program)
    emitted = backend.attribution.emitted
    [tested, *test.walk].sum { |node| emitted[node]&.instructions_per_use || 0 }
  end

  # Each game ends on its own, so the two are compared at the same moment.
  private def assert_same_totals(&game)
    rom = VBlank.build("TESTS", console: :gba, out: StringIO.new, err: StringIO.new, &game)
    played = Reference.new.run(rom.source_program, frames: 40)
    cartridge = VBlank::Diagnostics::Verifier.new(rom, frames: 40, vars: rom.var_addresses)

    refute_equal 0, played[:total]
    assert_equal played[:total], cartridge.var(:total)
  end
end
