# frozen_string_literal: true

require "test_helper"

# THE LOOPS AND TESTS EVERY CARTRIDGE LOWERING SHARES (Backends::ControlFlow), walked over a chip that
# writes no machine code: it keeps a list of the labels, jumps, loads and stores it was asked for, in
# order. So where a loop's labels go and which way each jump points is read straight off the list, with
# no cartridge built and no console played, and a mistake in the walk shows here for all four consoles
# at once. That each console writes those labels and jumps rightly in its own instructions is its
# checked run's to hold.
class TestControlFlow < Minitest::Test
  include VBlank::IR::Build

  # What a game loop is on a console, as the plan gives it: nothing before the first pass here, and
  # nothing placed as a pass ends.
  PlainLoop = Data.define(:before, :pass_end)

  # A lowering's part of the walk (ControlFlow's own comment lists it), each call written down.
  class RecordingChip
    include VBlank::IR::Backends::ControlFlow

    attr_reader :written

    def initialize
      @written = []
      @labels = Hash.new(0)
    end

    def fresh_label(what) = "#{what}#{@labels[what] += 1}"
    def place_label(label) = @written << [:label, label]
    def jump(label) = @written << [:jump, label]
    def jump_unless(condition, label) = @written << [:jump_unless, in_words(condition), label]
    def emit_value(operand) = @written << [:value, in_words(operand)]
    def emit_store(name) = @written << [:store, name]
    def emit_store_zero(name) = @written << [:zero, name]
    def emit_copy_variable(from, to) = @written << [:copy, from, to]
    def emit_increment(name) = @written << [:one_more, name]
    def keep_local(what) = :"own_#{what}"
    def folded(operand) = operand.is_a?(VBlank::IR::Node) && operand.kind == :int ? operand.value : nil
    def children_of(node) = [node.children, (node.else&.children if node.kind == :if) || []]
    def loop_statements(node) = node.children
    def console_loop(_node) = PlainLoop.new(before: [], pass_end: [])
    def game_loops = []
    def emit_scene(scene) = @written << [:scene, scene]

    # A condition known never to hold asks for no jump, as each lowering's does.
    def jump_if(condition, label)
      @written << [:jump_if, in_words(condition), label] unless folded(condition)&.zero?
    end

    # A statement of the walk's own goes back into it; any other is written down by its kind.
    def statement(node)
      return emit_control_flow_statement(node) if VBlank::IR::Backends::ControlFlow::STATEMENT_KINDS.include?(node.kind)

      @written << [:statement, node.kind, node.var]
    end

    private

    def in_words(operand)
      return operand unless operand.is_a?(VBlank::IR::Node)

      case operand.kind
      when :int then operand.value
      when :var_ref then operand.name
      when :binop then [in_words(operand.lhs), operand.op, in_words(operand.rhs)]
      else operand.kind
      end
    end
  end

  private def written_for(node)
    RecordingChip.new.tap { |chip| chip.statement(node) }.written
  end

  def test_a_test_jumps_past_its_body_and_past_its_other_side
    tested = if_(binop(:<, var_ref(:x), 5), set(:a, 1))
    tested.else = else_(set(:b, 2))

    assert_equal [[:jump_unless, [:x, :<, 5], "else1"], [:statement, :set, :a], [:jump, "end_if1"], [:label, "else1"],
                  [:statement, :set, :b], [:label, "end_if1"]], written_for(tested)
  end

  def test_a_test_with_no_other_side_makes_no_jump_over_one
    written = written_for(if_(binop(:<, var_ref(:x), 5), set(:a, 1)))

    assert_equal [[:jump_unless, [:x, :<, 5], "else1"], [:statement, :set, :a], [:label, "else1"], [:label, "end_if1"]], written
  end

  def test_a_test_whose_answer_is_known_keeps_only_the_side_that_runs
    never = if_(int(0), set(:a, 1))
    never.else = else_(set(:b, 2))

    assert_equal [[:statement, :set, :b]], written_for(never)
    assert_equal [[:statement, :set, :a]], written_for(if_(int(1), set(:a, 1)))
  end

  # Reference#exec_repeat: the count worked out once, the index compared before each turn and handed
  # to the game's variable only for a turn that runs, and one more after the body.
  def test_a_count_the_game_works_out_is_worked_out_once_and_kept
    written = written_for(repeat(var_ref(:n), :i, set(:a, 1)))

    assert_equal [[:value, :n], [:store, :own_count], [:zero, :own_index], [:label, "repeat1"],
                  [:jump_unless, %i[own_index < own_count], "end_repeat1"], %i[copy own_index i],
                  [:statement, :set, :a], %i[one_more own_index], [:jump, "repeat1"], [:label, "end_repeat1"]], written
  end

  # ...and a count written in the game is compared as the number it is, with no variable of its own:
  # two of the four consoles worked it out into one before this walk was shared.
  def test_a_count_written_in_the_game_is_compared_as_the_number_it_is
    written = written_for(repeat(40, :i, set(:a, 1)))

    assert_includes written, [:jump_unless, [:own_index, :<, 40], "end_repeat1"]
    refute_includes written, %i[store own_count]
  end

  def test_a_loop_with_no_variable_of_the_games_copies_its_index_nowhere
    refute_includes written_for(repeat(40, nil, set(:a, 1))).map(&:first), :copy
  end

  # `stop_when` is asked after the index is handed over and before the body, so a loop already
  # finished on its first turn runs the body no times.
  def test_a_loop_asks_whether_to_stop_before_its_body
    written = written_for(repeat(40, :i, set(:a, 1), stop_when: binop(:==, var_ref(:done), 1)))
    kinds = written.map(&:first)

    assert_operator kinds.index(:copy), :<, kinds.index(:jump_if)
    assert_operator kinds.index(:jump_if), :<, kinds.index(:statement)
    assert_includes written, [:jump_if, [:done, :==, 1], "end_repeat1"]
  end

  def test_a_loop_inside_a_loop_has_labels_of_its_own
    labels = written_for(repeat(3, :i, repeat(4, :j, set(:a, 1)))).select { |what, _| what == :label }.map(&:last)

    assert_equal %w[repeat1 repeat2 end_repeat2 end_repeat1], labels
  end

  # Reference#exec_case: the variable read once, before the first clause, so a scene that sets it to
  # the next scene does not start that one in the same pass.
  def test_a_choice_of_scenes_reads_its_variable_once
    written = written_for(case_(:state, [[0, :title], [1, :play]]))

    assert_equal [[:value, :state], [:store, :own_state], [:jump_unless, [:own_state, :==, 0], "next_clause1"],
                  %i[scene title], [:label, "next_clause1"], [:jump_unless, [:own_state, :==, 1], "next_clause2"],
                  %i[scene play], [:label, "next_clause2"]], written
  end

  def test_a_game_loop_goes_round_for_ever
    written = written_for(loop_(set(:a, 1)))

    assert_equal [[:label, "loop1"], [:statement, :set, :a], [:jump, "loop1"]], written
  end

  # The four lowerings write these kinds here and nowhere else.
  def test_every_cartridge_lowering_writes_its_loops_and_tests_here
    backends = VBlank::IR::Backends
    [backends::GBC, backends::SNES, backends::Genesis, backends::PS1].each do |console|
      lowering = console::Lowering

      assert_includes lowering.ancestors, backends::ControlFlow, console.name
      assert_empty backends::ControlFlow::STATEMENT_KINDS - lowering::STATEMENT_KINDS, console.name
      %i[emit_if emit_loop emit_repeat emit_beat emit_case].each do |writer|
        assert_equal backends::ControlFlow, lowering.instance_method(writer).owner, "#{console.name}##{writer}"
      end
    end
  end
end
