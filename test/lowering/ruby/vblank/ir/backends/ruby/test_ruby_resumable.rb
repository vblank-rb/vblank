# frozen_string_literal: true

require "test_helper"

# A routine that waits for a frame, made resumable (Native::Resumable) and printed as Ruby: the main
# routine hands each frame back to whoever calls it, and everything that says where the game is,
# down to a loop's count two calls deep, is in the game's own variables. So a game copied between
# frames, variable for variable, into a fresh one plays on exactly as the first would have: the
# heart of a save state.
class TestRubyResumable < Minitest::Test
  C = VBlank::IR::Backends::Native::C
  Resumable = VBlank::IR::Backends::Native::Resumable
  Printer = VBlank::IR::Backends::Ruby::Printer

  private def c_name(text) = C::Name.new(text: text)
  private def int(value) = C::Int.new(value: value)
  private def call(function, *args) = C::Call.new(function: c_name(function), args: args)
  private def wait = C::Eval.new(call: call("rg_wait_vblank"))

  # The trail takes a digit at each step the game passes: trail = trail * 10 + digit.
  private def mark(digit) = C::Assign.new(target: c_name("trail"), value: call("rg_add", call("rg_mul", c_name("trail"), int(10)), int(digit)))

  # main marks 1, calls inner, marks 9. inner marks 2, waits, then counts to three in a loop of
  # its own (a local), waiting and marking 3 each time round, and marks 4. A loop with no wait in it
  # counts to five as one step.
  private def program
    count = c_name("rg_local_count1")
    quick = c_name("rg_local_quick2")
    inner = C::Function.new(name: c_name("rg_routine_inner"), body: [
                              mark(2), wait,
                              C::Local.new(name: count, value: int(0)),
                              C::While.new(condition: call("rg_lt", count, int(3)),
                                           body: [wait, mark(3), C::Assign.new(target: count, value: call("rg_add", count, int(1)))]),
                              C::Local.new(name: quick, value: int(0)),
                              C::While.new(condition: call("rg_lt", quick, int(5)),
                                           body: [C::Assign.new(target: quick, value: call("rg_add", quick, int(1)))]),
                              C::Assign.new(target: c_name("quick_seen"), value: quick),
                              mark(4)
                            ])
    main = C::Function.new(name: c_name("rg_game_main"), exported: true,
                           body: [mark(1), C::Eval.new(call: call("rg_routine_inner")), mark(9)])
    [C::Global.new(name: c_name("trail")), C::Global.new(name: c_name("quick_seen")),
     C::Prototype.new(name: c_name("rg_routine_inner")), inner, main]
  end

  # A routine the runtime asks for an answer (a timer's tick) calling a routine the game is stopped
  # inside. main sets the flag and calls stop_or_not, which marks 5, waits while the flag is set,
  # and marks 6; then main marks 9. The tick clears the flag and calls stop_or_not too.
  private def program_with_an_answer
    flag = c_name("flag")
    stop_or_not = C::Function.new(name: c_name("rg_routine_stop_or_not"), body: [
                                    mark(5), C::If.new(condition: flag, body: [wait]), mark(6)
                                  ])
    main = C::Function.new(name: c_name("rg_game_main"), exported: true,
                           body: [C::Assign.new(target: flag, value: int(1)),
                                  C::Eval.new(call: call("rg_routine_stop_or_not")), mark(9)])
    tick = C::Function.new(name: c_name("rg_game_timer_ticks"), exported: true,
                           body: [C::Assign.new(target: flag, value: int(0)), C::Eval.new(call: call("rg_routine_stop_or_not"))])
    [C::Global.new(name: c_name("trail")), C::Global.new(name: c_name("quick_seen")), C::Global.new(name: flag),
     C::Prototype.new(name: c_name("rg_routine_stop_or_not")), stop_or_not, main, tick]
  end

  # A class whose objects are the game, printed as Ruby from the resumable tree, with readers for
  # the two globals the tests watch.
  private def game_class(items = program)
    text = Printer.new.print_file(Resumable.new(items).items)
    Class.new do
      attr_reader :trail, :quick_seen

      define_method(:rg_wait_vblank) { nil }
      class_eval(text)
    end
  end

  # The trail after each frame the game hands back, until it ends.
  private def trails(game)
    seen = []
    seen << game.trail while game.rg_game_main == 1
    seen << game.trail
  end

  def test_the_main_routine_hands_back_each_frame_and_carries_on_from_where_it_stopped
    game = game_class.new
    game.rg_game_setup

    assert_equal [12, 12, 123, 1233, 12_333_49], trails(game)
    assert_equal 5, game.quick_seen
  end

  # Stopped after two frames and copied (Object#dup copies every instance variable, the game's
  # globals, and nothing of the Ruby stack): the copy plays on as the first would have.
  def test_a_game_copied_between_frames_plays_on_as_the_first
    first = game_class.new
    first.rg_game_setup
    2.times { first.rg_game_main }

    assert_equal [123, 1233, 12_333_49], trails(first.dup)
  end

  # The tick runs the routine afresh from its start (5, 6) while the game is stopped inside it, and
  # the game then carries on from where it stopped (6, 9), as the interpreter runs a timer's handler.
  def test_a_routine_run_for_an_answer_runs_afresh_and_leaves_the_game_where_it_stopped
    game = game_class(program_with_an_answer).new
    game.rg_game_setup

    assert_equal 1, game.rg_game_main
    game.rg_game_timer_ticks

    assert_equal 556, game.trail
    assert_equal 0, game.rg_game_main
    assert_equal 55_669, game.trail
  end
end
