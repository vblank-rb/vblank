# frozen_string_literal: true

require "test_helper"

# The JavaScript the lowering prints, for what V8 does with it: every test of what a game does plays
# the printed code, but a routine V8 never optimises, or arithmetic left as a call for V8 to inline
# or not, would only show as a game that plays slowly.
class TestJSPrinter < Minitest::Test
  JS = VBlank::IR::Backends::JS

  private def program_of(manual: false, &block)
    options = VBlank::Cartridge::Options.new(frame_sync: manual ? :manual : :auto)
    builder = Builder.new(options: options)
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # Each printed function by its name, as its text.
  private def functions(source) = source.scan(/^function (\w+)\(\) \{\n(.*?)^\}$/m).to_h

  SUMS_IN_A_LONG_LOOP = 1_500 # Sums in the loop's body, many times what one function holds
  MOST_LINES_A_FUNCTION = 1_000 # Lines of the longest printed function, well inside what V8 optimises

  # A routine heavier than V8 optimises is printed in parts, each a function lighter than that, and a
  # resumable one keeps its steps in groups of functions too, so the loop a routine goes round with a
  # wait in it (a data pack's unpacking, which waits every few hundred bytes) runs in functions V8
  # optimises. The parts play as the routine did, checked against the interpreter on every frame: a
  # loop holding a wait goes on from where it waited, stops when it is told, and its count and index
  # (locals of the routine) are read in every part.
  def test_a_routine_heavier_than_v8_optimises_plays_in_parts
    program = program_of(manual: true) do
      total = var :total, 0
      passes = var :passes, 0
      stop = var :stop, 0
      func(:long) do
        repeat(40, stop_when: stop == 1) do |round|
          SUMS_IN_A_LONG_LOOP.times { |n| total += (round & 3) + (n & 1) }
          stop = 1 if round == 2 + passes
          wait_vblank
        end
        stop = 0
      end
      # The same loop with no wait in it: a plain routine in parts, whose loop is left from a part.
      func(:plain) do
        repeat(40, stop_when: stop == 1) do |round|
          SUMS_IN_A_LONG_LOOP.times { |n| total += (round & 1) + (n & 3) }
          stop = 1 if round == 3
        end
        stop = 0
      end
      game_loop do
        call :plain
        call :long
        passes += 1
        wait_vblank
      end
    end
    printed = functions(JS.new.lower(program))

    assert(printed.keys.any? { |name| name.match?(/\Arg_part_\d+_f_long\z/) }, "the long routine should be in parts")
    assert(printed.keys.any? { |name| name.match?(/\Arg_steps_\d+_f_long\z/) }, "its steps should be in groups")
    assert(printed.keys.any? { |name| name.match?(/\Arg_part_\d+_f_plain\z/) }, "the plain routine should be in parts")
    heaviest = printed.max_by { |_, body| body.lines.size }
    assert_operator heaviest.last.lines.size, :<, MOST_LINES_A_FUNCTION, "#{heaviest.first} is too long for V8 to optimise"
    v = game_player.run(program, frames: 12)

    assert_operator v[:passes], :>=, 2
    assert_equal Reference.new.run(program, frames: 12)[:total], v[:total]
  end

  # The game's own arithmetic is JavaScript's operators, written where it runs, and a shift by a
  # number written in the game too: as calls, V8 inlines only some of a long function's, and every
  # one it does not is a call per number.
  def test_the_games_arithmetic_is_written_inline
    source = JS.new.lower(program_of do
      x = var :x, 0
      game_loop { x.store!((x + 3) >> 2) }
    end)
    main = functions(source).fetch("rg_game_main")

    refute_match(/\brg_(add|shr)\(/, main)
    assert_match(/\(\(v_x \+ 3\) \| 0\)/, main)
    assert_match(/ >> 2\)/, main)
  end
end
