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

  # A ROUTINE LONGER THAN A METHOD HOLDS is printed in parts, each a method no longer than that,
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
