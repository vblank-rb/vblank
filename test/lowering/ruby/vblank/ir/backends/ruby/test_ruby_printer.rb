# frozen_string_literal: true

require "test_helper"

# The Ruby the lowering prints, for the rules a mistake in it would hide rather than show: every
# test of what a game does plays the printed code, but a condition always taken or a routine
# never called would only show where some test happened to look.
class TestRubyPrinter < Minitest::Test
  private def printed(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    text, = VBlank::IR::Backends::Ruby::Lowering.new(builder.program).text_and_gaps(VBlank::IR::Backends::Ruby::HEADLESS_FUNCTIONS)
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
  def test_a_condition_is_compared_with_nought
    nodes = nodes_of_method(printed do
      x = 0
      game_loop { x = 0 if x > 6 }
    end, :rg_game_main)

    compared = nodes.grep(Prism::IfNode).map(&:predicate).grep(Prism::CallNode).find do |test|
      test.name == :> && reads_instance_variable?(test.receiver, :@v_x) && integer?(test.arguments.arguments.first, 6)
    end
    refute_nil compared, "the game should test x > 6 as Ruby's own comparison"
    refute_includes call_names(nodes), :rg_gt
    loop_test = nodes.grep(Prism::WhileNode).first.predicate
    assert_equal :!=, loop_test.name
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
    assert_match(/__send__\(@r_\w+\[/, text)
  end
end
