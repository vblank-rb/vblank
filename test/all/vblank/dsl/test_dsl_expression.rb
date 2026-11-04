# frozen_string_literal: true

require "test_helper"
require "differential"

# The expression DSL: `var` hands back a Value handle you compare with ordinary
# Ruby operators to get a Condition, branch on with .then / .else, compose with
# & / |, and change a variable with .store! / .increase! / .decrease! / .clamp! / .abs! / ....
#
# These tests assert BEHAVIOR, not tree shape: a tiny program is built through
# the DSL, run on the reference backend's fake screen, and checked by the pixels
# it drew. So a comparison or branch is judged by what it makes the game show —
# never by re-describing the IR it builds. (Opcode-level checks belong in the
# IR-backend tests.) Guardrail tests assert a friendly error for misuse. A couple
# of the same programs confirmed on the Advance's cartridge are in
# test/lowering/gba/vblank/dsl/test_dsl_expression_cartridge.rb.
class TestDSLExpression < Minitest::Test
  include VBlank::IR::Build # constructors, for the guardrail trees
  include Differential

  # Build through the DSL and run it on the reference backend, returning the
  # interpreter — whose #screen holds the pixels the program drew. `held` pins a
  # button down for the whole run; `each_frame` supplies per-frame input.
  private def interpret(held: nil, each_frame: nil, **opts, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program

    ruby = game_player
    ruby = ruby.hold(held) if held
    ruby = ruby.input_each_frame(&each_frame) if each_frame
    ruby.run(builder.program, **opts)
    ruby
  end

  # Build the IR tree without running it — only the guardrail tests need this, to
  # see that a bad call raises before anything executes.
  private def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def pixel_at(interp, x, y)
    interp.screen.pixel(x, y)
  end

  UNDRAWN = 0 # the fake screen starts blank; an untouched pixel reads 0

  # ---- a comparison gates a draw ----

  def test_a_true_comparison_draws_and_a_false_one_does_not
    i = interpret do
      x = var :x, 5
      pixel 10, 10, :red if x > 3  # 5 > 3 — draws
      pixel 20, 20, :blue if x < 3 # 5 < 3 is false — skipped
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_each_comparison_operator_gates_correctly
    # Boundary rows (the equal case) separate > from >=, < from <=, and so on.
    # Red appears only when the comparison actually holds.
    [
      [:>,  5, 3, true],  [:>,  3, 3, false],
      [:<,  3, 5, true],  [:<,  3, 3, false],
      [:>=, 3, 3, true],  [:>=, 2, 3, false],
      [:<=, 3, 3, true],  [:<=, 4, 3, false],
      [:==, 3, 3, true],  [:==, 3, 4, false],
      [:!=, 3, 4, true],  [:!=, 3, 3, false],
    ].each do |op, a, b, holds|
      i = interpret do
        x = var :x, a
        pixel 1, 1, :red if x.public_send(op, b)
      end
      expected = holds ? Color.resolve(:red) : UNDRAWN
      assert_equal expected, pixel_at(i, 1, 1), "#{a} #{op} #{b} should be #{holds}"
    end
  end

  # `&` and `|` (both and either) work out both of their sides, even when the first settles the answer: a
  # second side that reads past the end of a list stops the game though the first side is false (or,
  # for `|`, true). On a checked run the interpreter stops first, so each lowering holds its own build
  # to this in its own folder (test_ps1_checked_run.rb on the PlayStation).
  def test_both_sides_of_and_and_or_are_worked_out_whatever_the_first_says
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
      error = assert_raises(VBlank::IR::ProgramError) { interpret(frames: 3, &game) }

      assert_match(/index 3 is out of range/, error.message)
    end
  end

  def test_arithmetic_feeds_a_comparison
    draw = lambda do |y_start|
      interpret do
        c = var :c, 5
        y = var :y, y_start
        pixel 2, 2, :red if y > c + 10 # threshold is c + 10 = 15
      end
    end
    assert_equal Color.resolve(:red), pixel_at(draw.call(20), 2, 2), "20 > 15 draws"
    assert_equal UNDRAWN, pixel_at(draw.call(12), 2, 2), "12 > 15 is false"
  end

  # ---- mutators, observed by where/whether the mark lands ----

  def test_value_mutators_change_the_variable
    # v walks 0 -> 5 -> 8 -> 7, then clamps down to 5; the marker's x reveals it.
    i = interpret do
      v = var :v, 0
      v = 5
      v += 3
      v -= 1
      v.clamp! 0, 5
      draw_rect_at :v, 20, 2, 2, :green # a variable position: x comes from v
    end
    assert_equal Color.resolve(:green), pixel_at(i, 5, 20)
    assert_equal UNDRAWN, pixel_at(i, 8, 20), "the pre-clamp 8 is not where it landed"
  end

  # A word that changes a variable ends in `!`, on the handle and as a flat verb alike.
  def test_the_words_that_change_a_variable_end_in_bang
    i = interpret do
      v = var :v, 0
      v = 5
      v += 3
      v -= 1
      copy_variable! :w, :v
      increase! :w, 10
      decrease! :w, 2
      store! :z, 1
      draw_rect_at :v, 20, 2, 2, :green # 7
      draw_rect_at :w, 30, 2, 2, :white # 15
      draw_rect_at :z, 40, 2, 2, :blue  # 1
    end

    assert_equal Color.resolve(:green), pixel_at(i, 7, 20)
    assert_equal Color.resolve(:white), pixel_at(i, 15, 30)
    assert_equal Color.resolve(:blue), pixel_at(i, 1, 40)
  end

  # ...and the same words without it say so rather than changing anything.
  #
  # Written out as source rather than made from a block, because a test made from a block
  # cannot be called from a worker, and these tests run in a pool of them.
  [%i[set 5], %i[add 1], %i[sub 1]].each do |word, amount|
    class_eval <<~TEST, __FILE__, __LINE__ + 1
      def test_a_variables_#{word}_without_its_bang_is_a_friendly_error
        err = assert_raises(ArgumentError) { tree { var(:v, 0).public_send(:#{word}, #{amount}) } }

        assert_match(/`v\\.#{word}` does not change a variable/, err.message)
        assert_match(/write `v [-+]?= #{amount}`/, err.message)
      end
    TEST
  end

  def test_a_flat_verb_without_its_bang_is_a_friendly_error
    err = assert_raises(ArgumentError) { tree { copy :w, :v } }

    assert_match(/`copy :w, :v` does not change a variable/, err.message)
    assert_match(/write `w = v`/, err.message)
  end

  # `add` and `sub` have a Ruby operator that makes a new number, so the message offers it.
  def test_add_and_sub_point_at_the_operator_that_makes_a_new_number
    add = assert_raises(ArgumentError) { tree { var(:v, 0).add 1 } }
    sub = assert_raises(ArgumentError) { tree { var(:v, 0).sub 1 } }

    assert_match(/`v \+ 1`/, add.message)
    assert_match(/`v - 1`/, sub.message)
  end

  # ...and a variable added to another variable reads as the two names, on the handle and as
  # a flat verb alike. Anything else puts the whole build in the message.
  def test_the_message_names_a_variable_operand_rather_than_describing_it
    handle = assert_raises(ArgumentError) { tree { var(:v, 0).add var(:step, 1) } }
    flat = assert_raises(ArgumentError) { tree { var :step, 1; add :v, :step } }

    assert_match(/`v \+ step`/, handle.message)
    assert_match(/`v \+ step`/, flat.message)
    assert_operator handle.message.length, :<, 300
    assert_operator flat.message.length, :<, 300
  end

  # An operand with no name to be written by — a number worked out on the spot — leaves the
  # advice out rather than describing itself, and so does an amount nobody gave.
  def test_the_message_leaves_out_advice_it_cannot_write
    worked_out = assert_raises(ArgumentError) { tree { v = var(:v, 0); v.add(v + 1) } }
    nothing = assert_raises(ArgumentError) { tree { add :v } }

    assert_match(/write `v \+= 1`\.\z/, worked_out.message.sub(/ \(at .*\)\z/, ""))
    assert_match(/write `v \+= 1`\.\z/, nothing.message.sub(/ \(at .*\)\z/, ""))
  end

  # A flat verb handed a number worked out on the spot has no name to write that number by,
  # so the message leaves it out. Describing it instead describes the whole build it holds.
  def test_a_flat_verb_leaves_out_a_number_it_cannot_name
    %i[set add sub copy].each do |verb|
      err = assert_raises(ArgumentError) { tree { v = var(:v, 0); public_send(verb, :w, v + 1) } }

      assert_match(/`#{verb} :w, \.\.\.` does not change a variable/, err.message)
      assert_match(/write `w [-+]?= 1`/, err.message)
      refute_match(/#</, err.message)
      assert_operator err.message.length, :<, 300
    end
  end

  # ...and a variable's handle is written by the variable's name.
  def test_a_flat_verb_names_a_handle_by_its_variable
    err = assert_raises(ArgumentError) { tree { step = var(:step, 1); add :v, step } }

    assert_match(/`add :v, step` does not change a variable/, err.message)
    assert_operator err.message.length, :<, 300
  end

  # The message ends with the line that wrote the verb, which is the one thing a person
  # migrating a whole game needs from it.
  def test_a_flat_verb_says_which_line_wrote_it
    err = assert_raises(ArgumentError) { tree { set :w, 5 } }

    assert_match(/\(at test_dsl_expression\.rb:\d+\)\z/, err.message)
  end

  # A pool field is a variable too, and its message names the field.
  def test_a_pool_fields_word_without_its_bang_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree do
        sparks = pool :spark, x: 0, capacity: 4
        sparks.each { |s| s.x.add 1 }
      end
    end

    assert_match(/`x\.add` does not change a variable/, err.message)
    assert_match(/write `x \+= 1`/, err.message)
    assert_match(/`x \+ 1`/, err.message)
  end

  # ...and an expression is not a variable at all, whichever of the two words it is given.
  def test_changing_an_expression_says_it_is_not_a_variable
    bare = assert_raises(ArgumentError) { tree { x = var(:x, 0); (x + 1).add 2 } }

    assert_match(/only a variable can be changed/, bare.message)
  end

  def test_unary_mutators_change_the_variable
    # d = -3; abs -> 3; +20 keeps the marker on-screen at x = 23.
    i = interpret do
      d = var :d, -3
      d.abs!
      d += 20
      draw_rect_at :d, 30, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 23, 30)
  end

  # Read as Ruby reads it, `d.abs <= 5` asks how far d is from nought and leaves d alone — the
  # way Integer#abs does. So the comparison holds, and d is still negative after it.
  def test_abs_inside_a_comparison_leaves_the_variable_alone
    i = interpret do
      d = var :d, -3
      pixel 1, 1, :red if d.abs <= 5
      pixel 2, 2, :blue if d < 0
    end
    assert_equal Color.resolve(:red), pixel_at(i, 1, 1), "3 is within 5"
    assert_equal Color.resolve(:blue), pixel_at(i, 2, 2), "d is still -3"
  end

  # THE FIVE AS NEW NUMBERS, each the number its `!` word would store, with d left at -3.
  # Each answer is drawn as a mark at x = 40 + answer on its own row, so a wrong one lands
  # in the wrong column. A bound and a step the game works out take a different path from
  # ones written down, so both are here.
  NEW_NUMBERS = [
    [3,   ->(d, _t, _s) { d.abs }],
    [0,   ->(d, _t, _s) { d.clamp(0, 9) }],
    [9,   ->(d, _t, _s) { (d + 20).clamp(0, 9) }],
    [-3,  ->(d, t, _s) { d.clamp(t - 20, t) }],        # already inside bounds worked out
    [1,   ->(d, t, _s) { d.approach(t, 4) }],
    [-1,  ->(d, t, s) { d.approach(t, s) }],           # a step of -2 read as a distance
    [-4,  ->(d, _t, _s) { d.approach(-4, 4) }],        # within a step: lands on it
    [3,   ->(d, _t, _s) { d.flip }],
    [-3,  ->(d, _t, _s) { d.negate_abs }],
    [-7,  ->(d, _t, _s) { (d + 10).negate_abs }],
    [-3,  ->(d, _t, _s) { d }],                        # and d itself, untouched
  ].freeze

  private def new_numbers_program(builder)
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      d = var :d, -3
      t = var :t, 10
      s = var :s, -2
      out = var :out, 0
      NEW_NUMBERS.each_with_index do |(_, number), row|
        out = number.call(d, t, s)
        draw_rect_at out + 40, row * 4, 2, 2, :white
      end
      halt
    end
    builder.finalize_program
    builder.program
  end

  def test_the_five_words_without_bang_are_new_numbers_on_both_backends
    program = new_numbers_program(Builder.new)
    i = game_player.run(program)

    NEW_NUMBERS.each_with_index do |(want, _), row|
      assert_equal Color.resolve(:white), pixel_at(i, 40 + want, row * 4), "row #{row} is #{want}"
    end
    assert_backends_agree(program, frames: 2)
  end

  # A number that holds a fraction keeps it: |-1.5| is 1.5, not 1 or 2.
  def test_a_new_number_keeps_the_fraction
    i = interpret do
      d = var :d, -1.5
      pixel 1, 1, :red if d.abs > 1.25
      pixel 2, 2, :red if d.abs < 1.75
      pixel 3, 3, :red if d.clamp(-1.0, 1.0) == -1.0
    end

    [1, 2, 3].each { |at| assert_equal Color.resolve(:red), pixel_at(i, at, at) }
  end

  def test_flip_reverses_the_sign
    # d = 5; flip -> -5; +25 brings the marker back on-screen at x = 20.
    i = interpret do
      d = var :d, 5
      d.flip!
      d += 25
      draw_rect_at :d, 40, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 20, 40)
  end

  # `flip` mutates a variable in place; unary minus is the same idea as an EXPRESSION —
  # `-speed` reads as far backwards as `speed` reads forwards, without disturbing speed.
  # It is what you reach for writing a wave that runs the other way.
  def test_unary_minus_is_the_value_the_other_way_round
    # d stays 5; the marker's x is 25 + (-5) = 20, so reading the marker proves both that
    # the sign flipped and that d itself was left alone.
    i = interpret do
      d = var :d, 5
      m = var :m, 0
      m = 25 + -d
      draw_rect_at :m, 40, 2, 2, :white
      draw_rect_at :d, 60, 2, 2, :green
    end
    assert_equal Color.resolve(:white), pixel_at(i, 20, 40)
    assert_equal Color.resolve(:green), pixel_at(i, 5, 60), "d was not changed by reading -d"
  end

  def test_division_truncates_toward_zero
    # 20 / 3 = 6 (truncated, not 6.66); the marker's x reveals the quotient.
    i = interpret do
      x = var :x, 20
      q = var :q, 0
      q = x / 3
      draw_rect_at :q, 10, 2, 2, :green
    end
    # The marker's left edge sits at x = q. green at 6 and blank at 5 pins q = 6
    # (7/... i.e. an untruncated 6.66 rounded up to 7 would leave 6 blank).
    assert_equal Color.resolve(:green), pixel_at(i, 6, 10)
    assert_equal UNDRAWN, pixel_at(i, 5, 10)
  end

  def test_dividing_a_negative_truncates_toward_zero_not_down
    # -7 / 2 = -3 on hardware (toward zero), not -4 (Ruby's floor). +30 keeps the
    # marker on-screen: -3 + 30 = 27, whereas a floored -4 would land at 26.
    i = interpret do
      n = var :n, -7
      q = var :q, 0
      q = n / 2
      q += 30
      draw_rect_at :q, 20, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 27, 20)
    assert_equal UNDRAWN, pixel_at(i, 26, 20), "a floored -4 would land here"
  end

  # By a written power of two, either side of nought and on either side of a half's edge. A shift alone
  # rounds down, so it is the negative numbers that tell the two apart.
  def test_dividing_by_a_written_power_of_two_truncates_toward_zero
    numbers = [-1, -2, -3, -4, -5, -7, -8, -9, -65_535, -65_536, -65_537, -1_000_000, 1, 7, 8, 65_537, 1_000_000]
    divisors = [1, 2, 4, 8, 16, 256, 65_536, 131_072]
    program = tree do
      screen :bitmap
      clear_screen :black
      wrong = var :wrong, 0
      numbers.each do |written|
        number = var :"number#{written.abs}#{written.negative? ? 'n' : 'p'}", written
        divisors.each do |divisor|
          wrong += 1 if number / divisor != written.fdiv(divisor).truncate
        end
      end
      halt
    end
    assert_equal 0, game_player.run(program, frames: 2)[:wrong]
  end

  # A divisor the game works out can come to nought on some frame, and then there is no
  # answer to give — so one is defined, and it is the same on both backends: 1 (or -1 for
  # a number below nought), and for `%` the number itself. +50 keeps the markers on screen.
  def test_dividing_by_a_worked_out_zero_gives_the_same_number_on_both_backends
    program = tree do
      screen :bitmap
      clear_screen :black
      nought = var :nought, 0
      over = var :over, 0
      under = var :under, 0
      left = var :left, 0
      over = var(:up, 30) / nought + 50
      under = var(:down, -30) / nought + 50
      left = var(:step, 80) % nought
      draw_rect_at over, 10, 2, 2, :green
      draw_rect_at under, 20, 2, 2, :red
      draw_rect_at left, 30, 2, 2, :white
      halt
    end
    i = game_player.run(program)

    assert_equal [51, 49, 80], [i[:over], i[:under], i[:left]]
    assert_equal Color.resolve(:green), pixel_at(i, 51, 10)
    assert_equal Color.resolve(:red), pixel_at(i, 49, 20)
    assert_equal Color.resolve(:white), pixel_at(i, 80, 30)
    assert_backends_agree(program, frames: 2)
  end

  # A nought WRITTEN as the divisor is a mistake the build can read, so it says so.
  def test_dividing_by_a_written_zero_is_a_friendly_error
    { "/ 0" => ->(x) { x / 0 }, "% 0" => ->(x) { x % 0 }, "/ 0.0" => ->(x) { x.to_f / 0.0 },
      "/ a fraction too small to keep" => ->(x) { x.to_f / 0.000001 } }.each do |written, work|
      err = assert_raises(ArgumentError, written) { tree { work.call(var(:x, 20)) } }

      assert_match(/divides by zero/, err.message, written)
      assert_match(/test_dsl_expression\.rb:\d+/, err.message, "#{written} should say which line wrote it")
    end
  end

  # ---- .then { } / .else { } ----

  def test_then_draws_when_true
    i = interpret do
      x = var :x, 9
      if x > 5
        pixel 10, 10, :red
      else
        pixel 20, 20, :blue
      end
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_else_draws_when_false
    i = interpret do
      x = var :x, 1
      if x > 5
        pixel 10, 10, :red
      else
        pixel 20, 20, :blue
      end
    end
    assert_equal Color.resolve(:blue), pixel_at(i, 20, 20)
    assert_equal UNDRAWN, pixel_at(i, 10, 10)
  end

  # ---- & / | condition composition ----

  def test_and_needs_both_conditions
    i = interpret do
      x = var :x, 5
      pixel 10, 10, :red if x > 1 && x < 9  # 5 is in range
      pixel 20, 20, :blue if x > 1 && x > 9 # 5 is not > 9
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_or_needs_either_condition
    i = interpret do
      x = var :x, 5
      pixel 10, 10, :red if x > 9 || x < 9  # 5 < 9
      pixel 20, 20, :blue if x > 9 || x < 0 # 5 is neither
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  # ---- input: held / pressed ----

  def test_held_draws_only_while_the_button_is_down
    down = interpret(held: :up) do
      pixel 10, 10, :red if held(:up)
    end
    assert_equal Color.resolve(:red), pixel_at(down, 10, 10)

    up = interpret do
      pixel 10, 10, :red if held(:up)
    end
    assert_equal UNDRAWN, pixel_at(up, 10, 10)
  end

  def test_pressed_fires_once_on_the_down_edge
    # :start is held every frame, but `pressed` is the edge — it fires once, so
    # the counter reaches 1 and stays there. Red marks "n == 1"; blue marks
    # "n >= 2", which must never appear if holding isn't counted as repeats.
    i = interpret(each_frame: ->(_frame) { [:start] }) do
      n = var :n, 0
      f = var :f, 0
      game_loop do
        wait_vblank
        n += 1 if pressed(:start)
        pixel 10, 10, :red if n == 1
        pixel 20, 20, :blue if n >= 2
        f += 1
        halt if f >= 4
      end
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10), "one down-edge => n == 1"
    assert_equal UNDRAWN, pixel_at(i, 20, 20), "holding is not repeated presses"
  end

  # ---- guardrails: misuse is a plain error, not a silent drop ----

  def test_held_and_pressed_reject_a_block
    # Writing held(:up) { ... } drops the block silently
    # (it attaches to `held`, not to an if). Catch it at the call site.
    %i[held pressed].each do |verb|
      err = assert_raises(ArgumentError) do
        tree { send(verb, :up) { halt } }
      end
      assert_match(/if/, err.message, "#{verb} should point the dev at if")
    end
  end

  def test_held_rejects_an_unknown_button
    assert_raises(ArgumentError) { tree { held(:turbo).then { halt } } }
  end

  def test_then_on_a_test_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree { (var(:x, 0) > 0).then { halt } }
    end
    assert_match(/write `if`/, err.message)
  end

  def test_mutating_an_expression_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        (x + 1).increase! 2 # (x + 1) is an expression, not a variable — can't mutate it
      end
    end
    assert_match(/variable/, err.message)
  end

  # The same kind of program confirmed on the Advance's cartridge, in the emulator, is in
  # test/lowering/gba/vblank/dsl/test_dsl_expression_cartridge.rb.
end
