# frozen_string_literal: true

require "test_helper"

# A game built as a Genesis cartridge and played in Genesis Plus GX does what the interpreter does,
# pass for pass (Genesis::CheckedRun): the game's numbers, its lists, its buttons and its routines, each
# carried out by 68000 code and its runtime. Each test is a small game of its own that leans on one
# of those, read back where a test of the game would read it; a disagreement anywhere along the run
# fails it.
class TestGenesisCheckedRun < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  def test_arithmetic_that_wraps_divides_and_shifts_agrees_with_the_interpreter
    run = checked(frames: 40) do
      a = 7
      b = -3
      c = 0
      game_loop do
        a = (a * 1103) + 12_345
        b = (b - a) / 7
        c = ((a % 97) ^ (b >> 3)) | ((a << 5) & 0xFF00)
      end
    end

    refute_equal 0, run[:a]
  end

  def test_comparisons_clamps_and_turning_round_agree_with_the_interpreter
    run = checked(frames: 30) do
      a = -40
      b = 0
      flags = 0
      game_loop do
        a += 3
        b = a.clamp(-20, 20)
        flags = 0
        flags += 1 if a < 0
        flags += 2 if a <= b
        flags += 4 if a > -5
        flags += 8 if a >= b
        flags += 16 if a == b
        flags += 32 if a != 7
        flags += 64 if a > 0 && b > 10
        b = b.abs - a.flip
      end
    end

    assert_operator run[:flags], :>, 0
  end

  def test_a_list_pushed_shifted_and_read_agrees_with_the_interpreter
    run = checked(frames: 24) do
      trail = list :trail, capacity: 5, width: :byte
      n = 120
      sum = 0
      game_loop do
        n += 3
        trail.push n
        trail.shift if trail.length > 4
        sum = trail[0] + trail[trail.length - 1]
      end
    end

    assert_equal 5 - 1, run.list(:trail).length
  end

  # A run of a table copied into a list lands in the list's own slots: the list declared before it
  # in work RAM keeps what it holds.
  def test_a_table_copied_into_a_list_agrees_and_leaves_the_list_before_it_alone
    run = checked(frames: 6) do
      lut = table :lut, [10, 20, 30, 40, 50], width: :byte, signed: false
      first = list :first, capacity: 3
      narrow = list :narrow, capacity: 4, width: :byte
      at = 0
      got = 0
      first.push 5
      game_loop do
        narrow.copy_from lut, at: at, count: 3
        got = narrow[2] + lut[at]
        at = (at + 1) % 4
      end
    end

    assert_equal [5], run.list(:first)
  end

  def test_a_list_read_out_of_range_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      checked(frames: 5) do
        body = list :body, capacity: 4
        body.push 10
        x = 0
        game_loop { x = body[3] }
      end
    end

    assert_match(/index 3 is out of range for list :body \(valid indexes are 0\.\.0\)/, error.message)
  end

  # `&` and `|` work out both sides (TestDSLExpression): played through a checked run, the interpreter
  # stops first and hides whether the cartridge did too, so the cartridge is played alone here.
  def test_the_cartridge_works_out_both_sides_of_and_and_or
    games = [
      proc do
        items = list :items, capacity: 4
        items.push 7
        hits = 0
        game_loop { hits += 1 if (hits > 100) & (items[3] > 0) }
      end,
      proc do
        items = list :items, capacity: 4
        items.push 7
        hits = 0
        game_loop { hits += 1 if (hits < 100) | (items[3] > 0) }
      end
    ]
    games.each do |game|
      error = assert_raises(VBlank::IR::ProgramError) { Genesis::HeadlessRun.new.run(program_of(&game), frames: 3) }

      assert_match(/index 3 is out of range for list :items/, error.message)
    end
  end

  def test_buttons_held_and_pressed_reach_the_game_on_the_frames_they_are_held
    run = Genesis::CheckedRun.new
    run.input_each_frame { |frame| frame % 3 == 1 ? %i[a right] : [] }.run(program_of do
      held_a = 0
      presses = 0
      game_loop do
        held_a += 1 if held(:a)
        presses += 1 if pressed(:right)
      end
    end, frames: 12)

    assert_operator run[:presses], :>=, 4
  end

  # Each of the pad's eight buttons pressed in turn, alone, a frame apart: each is counted under its own
  # name, so one wired to another's bit shows as a count in the wrong place.
  BUTTONS = %i[a b c start right left up down].freeze

  def test_every_button_reaches_the_game_under_its_own_name
    run = Genesis::CheckedRun.new
    run.input_each_frame { |frame| frame.even? ? [BUTTONS[(frame / 2) % BUTTONS.size]] : [] }
    run.run(program_of do
      BUTTONS.each do |button|
        count = var :"#{button}_count", 0
        game_loop_part = -> { count += 1 if pressed(button) }
        once_a_frame(&game_loop_part)
      end
      game_loop {}
    end, frames: 44)

    counts = BUTTONS.map { |button| run[:"#{button}_count"] }
    assert(counts.all? { |count| count >= 2 }, counts.inspect)
  end

  def test_buttons_held_from_power_on_are_pressed_at_the_first_frame
    run = Genesis::CheckedRun.new.hold(:start, :b)
    run.run(program_of do
      started = 0
      game_loop do
        started += 1 if pressed(:start)
        started += 10 if held(:b)
      end
    end, frames: 5)

    assert_operator run[:started], :>, 0
  end

  # What is left after dividing by a power of two takes the divisor's sign, as Ruby's `%` does: -1
  # % 16 is 15. Counted down through nought and far below it, by 1, 2, 16, 1024 and 2^30.
  def test_what_is_left_by_a_power_of_two_takes_the_divisors_sign
    run = checked(frames: 12) do
      a = 2_000_037
      left = 0
      game_loop do
        left = (a % 1) + ((a % 2) * 10) + ((a % 16) * 100) + ((a % 1024) * 10_000) + (a % 1_073_741_824)
        a -= 777_781
      end
    end

    assert_operator run[:a], :<, 0
  end

  def test_scenes_picked_by_a_variable_agree_with_the_interpreter
    run = checked(frames: 20) do
      state = 0
      ticks = 0
      scene(:title) { ticks += 1; state = 1 if ticks > 3 }
      scene(:play) { ticks += 10; if ticks > 50 then state = 0; ticks = 0 end }
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end

    assert_operator run[:ticks], :>, 0
  end

  def test_a_routine_picked_by_a_number_and_a_counted_loop_agree_with_the_interpreter
    run = checked(frames: 12) do
      total = 0
      pick = 0
      func(:one) { total += 1 }
      func(:two) { total += 20 }
      func(:three) { total += 300 }
      game_loop do
        call %i[one two three], number: pick
        pick = (pick + 1) % 4
        repeat(3) { |i| total += i }
      end
    end

    assert_operator run[:total], :>, 0
  end

  def test_a_game_that_halts_ends_where_the_interpreter_ends
    run = checked(frames: 60) do
      x = 0
      game_loop do
        x += 1
        halt if x >= 9
      end
    end

    assert_equal 9, run[:x]
  end

  def test_a_game_that_never_waits_runs_to_its_end
    run = checked do
      x = var :x, 5
      x = x * x
    end

    assert_equal 25, run[:x]
  end

  def test_randomness_and_timers_agree_with_the_interpreter
    run = checked(frames: 40) do
      seed 777
      hits = 0
      ticks = 0
      rings = 0
      beat = timer :beat, per_second: 13
      beat.on_tick { rings += 1 }
      game_loop do
        hits += 1 if chance(50)
        ticks = beat.ticks
      end
    end

    assert_operator run[:hits], :>, 0
  end

  # A pass too heavy for one frame spans several, and what keeps real time — `once_a_frame` —
  # moves on by every frame the pass took, on the interpreter too.
  def test_a_pass_that_takes_several_frames_keeps_real_time_as_the_interpreter_does
    run = checked(frames: 12) do
      x = 1
      frames = 0
      passes = 0
      once_a_frame { frames += 1 }
      game_loop do
        passes += 1
        repeat(1000) { x = (x * 1103) + 12_345 }
      end
    end

    assert_operator run[:frames], :>, run[:passes], "a pass spanned more than one frame"
  end

  # A byte read out of a block of data the program declares, built as IR since no verb says it alone.
  def test_a_byte_of_declared_data_is_read_as_the_interpreter_reads_it
    build = VBlank::IR::Build
    game = build.program(
      build.data(:bytes, "\x05\xFA\x07".b),
      build.set(:first, build.data_byte(:bytes, 0)),
      build.loop_(build.wait_vblank, build.set(:second, build.data_byte(:bytes, 1)),
                  build.set(:total, build.binop(:+, build.data_byte(:bytes, 2), build.var_ref(:second)))),
      console: :genesis
    )
    run = Genesis::CheckedRun.new.run(game, frames: 4)

    assert_equal [5, 250, 257], [run[:first], run[:second], run[:total]]
  end

  def test_a_routine_that_can_call_itself_is_refused_in_plain_words
    program = VBlank::IR::Build.program(
      VBlank::IR::Build.func(:again, VBlank::IR::Build.call(:again)), VBlank::IR::Build.call(:again)
    )
    error = assert_raises(Genesis::LoweringError) { Genesis.new.build(program) }

    assert_match(/can call itself again/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames: nil, &game)
    Genesis::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
