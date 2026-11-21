# frozen_string_literal: true

require "test_helper"

# The Ruby the lowering prints, for the rules a mistake in it would hide rather than show: every
# test of what a game does plays the printed code, but a condition always taken or a routine
# never called would only show where some test happened to look.
class TestRubyPrinter < Minitest::Test
  private def printed(&block) = printed_program(program_of(&block))

  private def printed_program(program)
    text, = VBlank::IR::Backends::Ruby::Lowering.new(program).text_and_gaps(VBlank::IR::Backends::Ruby::HEADLESS_FUNCTIONS)
    text
  end

  # Every node of the printed method +name+, read back by Ruby's own parser, so a test asks what the
  # code is and not how it is spaced.
  private def nodes_of_method(text, name)
    method = every_node(Prism.parse(text).value).find { |node| node.is_a?(Prism::DefNode) && node.name == name }
    refute_nil method, "the printed game has no method #{name}"
    every_node(method)
  end

  private def every_node(node) = [node, *node.compact_child_nodes.flat_map { |child| every_node(child) }]

  private def reads_instance_variable?(node, name) = node.is_a?(Prism::InstanceVariableReadNode) && node.name == name

  private def integer?(node, value) = node.is_a?(Prism::IntegerNode) && node.value == value

  private def call_names(nodes) = nodes.grep(Prism::CallNode).map(&:name)

  # In Ruby nought is true, so a number taken as a condition is compared with nought, a loop's
  # included; a comparison taken as one is Ruby's own, with no call to answer 1 or 0.
  #
  # The number taken as a condition is a tree made by hand: game code always writes a test.
  def test_a_condition_is_compared_with_nought
    nodes = nodes_of_method(printed do
      x = 0
      game_loop { x = 0 if x > 6 }
    end, :rg_game_main)

    compared = if_tests(nodes).find do |test|
      test.name == :> && reads_instance_variable?(test.receiver, :@v_x) && integer?(test.arguments.arguments.first, 6)
    end
    refute_nil compared, "the game should test x > 6 as Ruby's own comparison"
    refute_includes call_names(nodes), :rg_gt

    build = VBlank::IR::Build
    counted = build.program(build.set(:left, 3), build.loop_(build.if_(build.var_ref(:left), build.sub(:left, 1)), build.wait_vblank))
    number_tests = if_tests(nodes_of_method(printed_program(counted), :rg_game_main))
    with_nought = number_tests.find do |test|
      test.name == :!= && reads_instance_variable?(test.receiver, :@v_left) && integer?(test.arguments.arguments.first, 0)
    end
    refute_nil with_nought, "the game should test left != 0, since nought is true in Ruby"
  end

  private def if_tests(nodes) = nodes.grep(Prism::IfNode).map(&:predicate).grep(Prism::CallNode)

  # A test of both or either of two comparisons is Ruby's own, with no call to the runtime: the loop
  # that tests an index before it writes a list made one on every turn.
  def test_both_of_two_comparisons_is_written_inline
    nodes = nodes_of_method(printed do
      x = 0
      hits = 0
      game_loop do
        hits += 1 if (x >= 0) & (x < 5)
        hits += 1 if (x < 0) | (x > 5)
        x += 1
      end
    end, :rg_game_main)

    refute_includes call_names(nodes), :rg_both
    refute_includes call_names(nodes), :rg_either
    assert nodes.any?(Prism::AndNode), "both of two plain comparisons should be Ruby's &&"
    assert nodes.any?(Prism::OrNode), "either of two plain comparisons should be Ruby's ||"
  end

  # `&` and `|` work out both sides (TestDSLExpression), so a second side that can stop the game is
  # worked out even when the first settles the answer. Played through a checked run the interpreter
  # stops first and hides whether the program did too, so the program is played alone here.
  def test_the_program_works_out_both_sides_of_and_and_or
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
      error = assert_raises(VBlank::IR::ProgramError) { VBlank::IR::Backends::Ruby::HeadlessRun.new.run(program_of(&game), frames: 3) }

      assert_match(/index 3 is out of range for list :items/, error.message)
    end
  end

  # The game's own sums are Ruby's +, written where they run rather than a call to the runtime for
  # each: YJIT compiles an operator on small numbers to a few instructions, and a method only as a
  # call. A sum still comes round at 32 bits (Int32), through rg_i32, called only for one that does.
  def test_a_sum_is_written_inline
    nodes = nodes_of_method(printed do
      x = 0
      game_loop { x += 3 }
    end, :rg_game_main)

    summed = nodes.grep(Prism::LocalVariableWriteNode).map(&:value).grep(Prism::CallNode).find do |sum|
      sum.name == :+ && reads_instance_variable?(sum.receiver, :@v_x) && integer?(sum.arguments.arguments.first, 3)
    end
    refute_nil summed, "the game should keep x + 3 in a local, as Ruby's own +"
    refute_includes call_names(nodes), :rg_add
    wrapped = nodes.grep(Prism::IfNode).find { |choice| call_names(every_node(choice)).include?(:rg_i32) }
    refute_nil wrapped, "a sum past 32 bits should come round through rg_i32, and only when it is"
  end

  # A list of bytes that is always full is read and written as its String's own byte, not through the
  # list's methods: an unpacking writes its whole pack into one. A byte keeps the low bits and reads
  # back signed, as the list's own methods keep it. Checked against the interpreter on every frame.
  def test_an_always_full_list_of_bytes_is_read_and_written_in_place
    program = program_of do
      bytes = list :bytes, capacity: 4, width: :byte, full_of: 0
      pass = 0
      seen = var :seen, 0
      game_loop do
        bytes[pass & 3] = 198 + pass if (pass >= 0) & (pass < 4)
        seen += bytes[(pass + 3) & 3]
        pass += 1
      end
    end
    text = printed_program(program)

    refute_match(/@l_\w*bytes\.(set|get)\(/, text)
    assert_match(/\.setbyte\(/, text)
    assert_match(/\.getbyte\(/, text)
    run = game_player.run(program, frames: 6)

    assert_equal [-58, -57, -56, -55], run.list(:bytes)
  end

  # ...and an index outside it stops the game, though the test before the write says it is nought or
  # more: the list is shorter than the test allows. Played alone, as the interpreter stops first.
  def test_an_index_past_an_always_full_list_of_bytes_stops_the_game
    games = [
      proc do
        bytes = list :bytes, capacity: 4, width: :byte, full_of: 0
        pass = 0
        game_loop do
          bytes[pass + 2] = 1 if (pass >= 0) & (pass < 9)
          pass += 1
        end
      end,
      proc do
        bytes = list :bytes, capacity: 4, width: :byte, full_of: 0
        pass = 0
        seen = 0
        game_loop do
          seen += bytes[1 - pass]
          pass += 1
        end
      end
    ]
    [/index 4 is out of range for list :bytes/, /index -1 is out of range for list :bytes/].zip(games).each do |words, game|
      error = assert_raises(VBlank::IR::ProgramError) { VBlank::IR::Backends::Ruby::HeadlessRun.new.run(program_of(&game), frames: 4) }

      assert_match words, error.message
    end
  end

  # A loop cut into steps, as one that waits every few turns is, turns as a loop of its own: its body's
  # step goes back to itself through the steps that count it on and test it, written in place, and
  # the step it is on is a Ruby local. The routine's counter is written only where it leaves, just
  # before a `return`. Checked against the interpreter on every frame, waits and all.
  def test_a_loop_cut_into_steps_turns_without_writing_its_counter
    program = program_of do
      total = var :total, 0
      unwaited = var :unwaited, 0
      game_loop do
        repeat(50) do |turn|
          total += turn
          unwaited += 1
          if unwaited >= 7
            unwaited = 0
            wait_vblank
          end
        end
      end
    end
    nodes = nodes_of_method(printed_program(program), :rg_game_main)

    counter_writes = nodes.grep(Prism::StatementsNode).flat_map do |list|
      list.body.each_cons(2).select { |write, _| write.is_a?(Prism::InstanceVariableWriteNode) && write.name == :@rg_game_main_step }
    end
    refute_empty counter_writes
    counter_writes.each { |_, after| assert_kind_of Prism::ReturnNode, after, "the counter should be written only as the routine leaves" }
    looped = nodes.grep(Prism::WhileNode).select { |loop| every_node(loop.statements).any?(Prism::WhileNode) }
    refute_empty looped, "the loop's body should be a loop of its own inside the choice of step"
    run = game_player.run(program, frames: 20)

    assert_operator run[:total], :>, 0
  end

  # A routine longer than a method holds is printed in parts, each a method no longer than that,
  # since Ruby's compiler needs stack for every branch in a method and a Ractor has little. The
  # parts play as the routine did: a loop whose body is in parts still stops when it is told, its
  # count and index (locals of the routine) are read in every part, and the game loop it is called
  # from goes on to its next pass. Checked against the interpreter on every frame.
  SUMS_IN_A_LONG_LOOP = 1_500

  def test_a_routine_longer_than_a_method_holds_plays_in_parts
    program = program_of do
      total = var :total, 0
      passes = var :passes, 0
      stop = var :stop, 0
      func(:long) do
        repeat(40, stop_when: stop == 1) do |round|
          SUMS_IN_A_LONG_LOOP.times { |n| total += (round & 3) + (n & 1) }
          stop = 1 if round == 2 + passes
        end
        stop = 0
      end
      game_loop do
        call :long
        passes += 1
      end
    end
    printed = printed_program(program)
    longest = method_bodies(printed).max_by { |body| body.scan(/ \? |\bif\b|\bwhile\b/).size }

    assert_match(/^def rg_part_\d+_f_long$/, printed)
    assert_operator longest.scan(/ \? |\bif\b|\bwhile\b/).size, :<, 4_000, "a method holds too many branches"
    v = game_player.run(program, frames: 3)
    passes = v[:passes]

    assert_operator passes, :>=, 2
    assert_equal (0...passes).sum { |pass| (0..(2 + pass)).sum { |round| ((round & 3) * SUMS_IN_A_LONG_LOOP) + (SUMS_IN_A_LONG_LOOP / 2) } }, v[:total]
  end

  # A routine of many sums keeps each sum in a local of its own while it checks it for coming
  # round, and YJIT on arm64 stops Ruby itself (a panic in its assembler) on a method of more than
  # about 490 locals once that method is called often enough to compile. So no printed method has
  # more than MOST_LOCALS_A_METHOD, and the routine, called every frame, plays as it does on the
  # interpreter: under YJIT on the Ruby run, which turns it on (Lowering::Run#yjit). Too few branches to be printed in parts, so the sums alone are long;
  # its loops give it many locals of its own besides (each loop's count and index).
  SUMS_IN_A_ROUTINE = 300
  LOOPS_IN_A_ROUTINE = 150

  def test_a_routine_of_many_sums_keeps_few_locals_and_plays
    program = program_of do
      total = var :total, 0
      func(:many_sums) do
        SUMS_IN_A_ROUTINE.times { |n| total += (n & 3) + 1 }
        LOOPS_IN_A_ROUTINE.times { repeat(2) { |i| total += i * 0 } }
      end
      game_loop { call :many_sums }
    end
    most = VBlank::IR::Backends::Ruby::Printer::MOST_LOCALS_A_METHOD
    locals = locals_by_method(printed_program(program))

    assert_operator locals.values.max, :<=, most, "a printed method has more locals than YJIT compiles: #{locals.max_by(&:last)}"
    a_call = SUMS_IN_A_ROUTINE.times.sum { |n| (n & 3) + 1 }
    total = game_player.run(program, frames: 60)[:total]

    assert_equal 0, total % a_call
    assert_operator total / a_call, :>=, 50, "the routine should be called often enough for YJIT to compile it"
  end

  # Where InstructionSequence#to_a keeps a method's local table.
  LOCAL_TABLE = 10

  # How many locals each method of the printed game has, as Ruby's compiler counts them.
  private def locals_by_method(text)
    by_method = {}
    RubyVM::InstructionSequence.compile(text).each_child { |method| by_method[method.label] = method.to_a[LOCAL_TABLE].size }
    by_method
  end

  private def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def method_bodies(text) = text.scan(/^def \w+\n.*?^end$/m)

  # What the game keeps is the game's own, from rg_game_setup on; a routine is a method, and one
  # picked by its number is called by that method's name.
  def test_a_routine_picked_by_number_is_called_by_name
    text = printed do
      which = 0
      func(:left) { which = 1 }
      func(:right) { which = 0 }
      game_loop { call %i[left right], number: which }
    end

    setup = text[/^def rg_game_setup\n.*?^end$/m]
    assert_match(/^  @v_which = 0$/, setup)
    assert_match(/^def f_left$/, text)
    assert_match(/^  @r_\w+ = \[-> \{ f_left \}, -> \{ f_right \}\]\.freeze$/, setup)
    assert_match(/@r_\w+\[.*\]\.call/, text)
  end
end
