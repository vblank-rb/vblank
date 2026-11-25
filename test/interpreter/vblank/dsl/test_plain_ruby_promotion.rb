# frozen_string_literal: true

require "test_helper"

# Each rule of PlainRuby::Promotion, asked of a small block or a value: whether a name or a place
# becomes a game variable, and the reason it gives. The behaviour every rule adds up to is
# asserted by the plain-Ruby tests that play games; these name the rule that decided. It plays no
# game, so it sits with the run whose player is the interpreter rather than in every lowering's.
class TestPlainRubyPromotion < Minitest::Test
  Promotion = VBlank::DSL::PlainRuby::Promotion

  # A test as the rewritten block hands one over, the game's or one decided while building.
  OpenTest = Data.define(:game) do
    def game? = game
  end

  private def block_of(source)
    Prism.parse("proc do\n#{source}\nend\n").value.statements.body.first.block
  end

  private def promotion_of(block) = VBlank::DSL::PlainRuby::LocalNames.new(block).promotion

  # The +index+th node under +block+ of one of +kinds+ that names +name+, in source order.
  private def node_named(block, name, kinds, index = 0)
    found = []
    walk = lambda do |node|
      found << node if kinds.any? { |kind| node.is_a?(kind) } && node.respond_to?(:name) && node.name == name
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(block)
    found.sort_by { |node| node.location.start_offset }.fetch(index)
  end

  private def write_of(block, name, index = 0) = node_named(block, name, VBlank::DSL::PlainRuby::LocalNames::CHANGES, index)

  private def read_of(block, name, index = 0) = node_named(block, name, [Prism::LocalVariableReadNode], index)

  private def first_of(block, kind)
    return block if block.is_a?(kind)

    block.compact_child_nodes.each do |child|
      found = first_of(child, kind)
      return found if found
    end
    nil
  end

  private def local_reason(source, name, index = 0)
    block = block_of(source)
    promotion_of(block).local(write_of(block, name, index)).reason
  end

  # The build-time half: is a local a game variable?

  def test_a_local_made_by_var_is_a_game_variable
    assert_equal :made_by_var, local_reason("hp = var(:hp, 0)", :hp)
  end

  def test_a_number_changed_in_game_code_is_a_game_variable
    answer = promotion_of(block = block_of("hp = 3\ngame_loop do\n  hp -= 1\nend")).local(write_of(block, :hp))

    assert_equal :changed_in_game_code, answer.reason
    assert_predicate answer, :promoted?
  end

  def test_a_working_out_moved_on_in_a_game_block_below_it_is_a_game_variable
    source = "game_loop do\n  back = made - 1\n  repeat(3) { back += 1 }\nend"

    assert_equal :changed_in_game_block, local_reason(source, :back)
  end

  def test_a_number_game_code_only_reads_stays_plain
    answer = promotion_of(block = block_of("count = 3\ngame_loop do\n  draw(count)\nend")).local(write_of(block, :count))

    assert_equal :unchanged_in_game_code, answer.reason
    assert_predicate answer, :plain?
    refute_predicate answer, :promoted?
  end

  def test_a_methods_argument_stays_plain
    assert_equal :argument, local_reason("def bump(step)\n  step += 1\nend", :step)
  end

  def test_a_number_changed_from_a_block_only_running_can_place_is_decided_while_running
    answer = promotion_of(block = block_of("count = 0\nnames.each { count += 1 }")).local(write_of(block, :count))

    assert_equal :changed_from_unplaced_block, answer.reason
    assert_predicate answer, :decided_while_running?
  end

  def test_a_read_of_such_a_number_outside_that_block_reads_it_as_ruby_holds_it
    block = block_of("count = 0\nnames.each { count += 1 }\nshow(count)")

    assert_equal :read_outside_unplaced_block, promotion_of(block).local(read_of(block, :count)).reason
  end

  def test_an_instance_variable_is_no_local
    block = block_of("@hp = 3")

    assert_equal :not_a_local, promotion_of(block).local(first_of(block, Prism::InstanceVariableWriteNode)).reason
  end

  def test_the_line_that_makes_a_variable_declares_it_in_setting_up_and_starts_it_in_game_code
    setting_up = block_of("hp = 3\ngame_loop do\n  hp -= 1\nend")
    in_game_code = block_of("game_loop do\n  hp = 3\n  hp -= 1\nend")

    assert_equal :declare, promotion_of(setting_up).action_for(write_of(setting_up, :hp))
    assert_equal :assign, promotion_of(setting_up).action_for(write_of(setting_up, :hp, 1))
    assert_equal :start, promotion_of(in_game_code).action_for(write_of(in_game_code, :hp))
  end

  # Before a test the game may make

  private def before_if(source)
    block = block_of(source)
    test = first_of(block, Prism::IfNode)
    promotion = promotion_of(block)
    [promotion.before_test(test, [test.statements, test.subsequent]), promotion, block]
  end

  def test_a_name_changed_under_a_test_and_read_after_it_is_promoted
    promotions, promotion, block = before_if("x = 0\nif flag\n  x = 1\nend\nshow(x)")
    name = promotions.names.first

    assert_equal [:x, :read_after_test, false], [name.name, name.reason, name.on_every_side]
    assert_equal :read_after_test, promotion.write_under_test(write_of(block, :x, 1)).reason
  end

  def test_a_name_written_on_every_side_can_never_stay_nil
    promotions, = before_if("x = 0\nif flag\n  x = 1\nelse\n  x = 2\nend\nshow(x)")

    assert promotions.names.first.on_every_side
  end

  def test_a_name_a_loop_changes_and_reads_next_round_is_promoted
    block = block_of("at = 0\nwhile at < 4\n  at += 1\nend")
    loop = first_of(block, Prism::WhileNode)

    assert_equal [:read_next_round], promotion_of(block).before_test(loop, [loop.statements]).names.map(&:reason)
  end

  def test_a_name_read_nowhere_after_its_test_stays_plain
    promotions, promotion, block = before_if("x = 0\nif flag\n  x = 1\nend")

    assert_empty promotions.names
    refute_predicate promotions, :changes?
    assert_equal :not_read_after_test, promotion.write_under_test(write_of(block, :x, 1)).reason
  end

  def test_instance_variables_and_slots_at_plain_keys_are_promoted
    promotions, = before_if("h = {}\nif flag\n  @hp = 1\n  h[:a] = 1\nend")

    assert_equal [nil, [:a]], promotions.places.map { |place| place.keys&.map(&:unescaped)&.map(&:to_sym) }
  end

  def test_a_slot_at_a_worked_out_key_is_left_but_still_counts_as_a_change
    promotions, = before_if("h = {}\ni = 0\nif flag\n  h[i + 1] = 1\nend")

    assert_empty promotions.places
    assert_predicate promotions, :changes?
  end

  # A copy of a plain local's number

  private def kept_reason(source, name)
    block = block_of(source)
    promotion_of(block).kept_copy(write_of(block, name)).reason
  end

  def test_a_working_out_changed_before_it_is_read_keeps_its_number
    block = block_of("hp = var(:hp, 0)\ngame_loop do\n  d = hp + 1\n  hp += 1\n  draw(d)\nend")
    answer = promotion_of(block).kept_copy(write_of(block, :d))

    assert_equal [:copies_numbers, :numbers], [answer.reason, answer.copy]
  end

  def test_a_working_out_nothing_changes_before_its_read_keeps_no_copy
    assert_equal :unchanged_before_read, kept_reason("hp = var(:hp, 0)\ngame_loop do\n  d = hp + 1\n  shown = d\nend", :d)
  end

  def test_a_local_read_whole_from_a_game_variable_keeps_its_number
    block = block_of("hp = var(:hp, 0)\ngame_loop do\n  first = hp\n  hp -= 1\n  draw(first)\nend")

    assert_equal :every_variable, promotion_of(block).kept_copy(write_of(block, :first)).copy
  end

  def test_a_local_that_only_hands_a_variable_to_the_parts_it_builds_keeps_no_copy
    assert_equal :handed_whole_in_setup, kept_reason("setting = @setting\nMenus.new(setting: setting)", :setting)
  end

  def test_a_game_variable_is_no_plain_local_to_copy
    assert_equal :not_a_plain_local, kept_reason("hp = var(:hp, 0)", :hp)
  end

  def test_a_button_read_while_setting_up_and_kept_for_game_code_is_noted
    block = block_of("advance = pressed(:a)\ngame_loop do\n  draw(advance)\nend")

    assert promotion_of(block).button_kept?(write_of(block, :advance))
  end

  def test_a_routine_handed_a_plain_number_cannot_change_it
    block = block_of("count = 3\ncall :step, count")
    names = VBlank::DSL::PlainRuby::LocalNames.new(block)

    assert names.promotion.plain_number?(names.local_of(write_of(block, :count)))
  end

  # The run-time half

  def test_a_value_under_a_test_decided_while_building_is_not_promoted
    assert_equal :test_decided_while_building, Promotion.value_under_test(3, OpenTest.new(false)).reason
  end

  def test_a_number_under_a_game_test_is_promoted
    assert_equal :changed_under_game_test, Promotion.value_under_test(3, OpenTest.new(true)).reason
  end

  def test_something_only_ruby_can_hold_is_not_promoted
    assert_equal :not_kept_by_game, Promotion.value_under_test(Object.new, OpenTest.new(true)).reason
  end

  def test_a_name_holding_the_variable_an_outer_game_test_made_for_it_keeps_it
    own = Builder.new.hidden_variable(:promoted)

    assert_equal :holds_own_variable, Promotion.value_under_test(own, OpenTest.new(true), OpenTest.new(true)).reason
  end

  def test_an_instance_variable_is_followed_only_while_game_code_is_recorded
    builder = Builder.new
    VBlank::DSL::PlainRuby::InstanceVariables.name_game_variables(builder, :hp)
    answers = []
    builder.game_loop do
      answers << Promotion.instance_variable(builder, 3, :@hp).reason
      answers << Promotion.instance_variable(builder, nil, :@hp).reason
      answers << Promotion.instance_variable(builder, 3, :@other).reason
    end

    assert_equal :setting_up, Promotion.instance_variable(builder, 3, :@hp).reason
    assert_equal %i[named_instance_variable named_still_nil not_named], answers
  end

  def test_a_place_holding_a_plain_value_is_promoted_and_one_holding_a_variable_or_nothing_is_not
    assert_equal :holds_plain_value, Promotion.held(3).reason
    assert_equal :holds_nothing, Promotion.held(nil).reason
    assert_equal :holds_variable, Promotion.held(Builder.new.var(:hp, 0)).reason
  end

  def test_only_a_ruby_collections_slot_at_a_key_known_while_building_is_promoted
    hp = Builder.new.var(:hp, 0)

    assert_equal :slot_named_while_building, Promotion.slot({ a: 1 }, [:a]).reason
    assert_equal :not_a_ruby_collection, Promotion.slot(Object.new, [:a]).reason
    assert_equal :key_worked_out, Promotion.slot([1, 2], [hp]).reason
  end

  def test_a_number_changed_from_an_unplaced_block_is_a_variable_only_while_recording
    assert_equal :changed_while_recording, Promotion.unplaced_change(3, true).reason
    assert_equal :setting_up, Promotion.unplaced_change(3, false).reason
    assert_equal :not_a_number, Promotion.unplaced_change(:fast, true).reason
  end

  def test_an_instance_variable_moved_in_game_code_copies_a_variable_it_does_not_own
    builder = Builder.new
    given = builder.var(:given, 0)
    own = VBlank::DSL::PlainRuby::Writes.keep_as_own(builder.var(:own, 0), self, :@x)

    assert_equal :given_variable_it_does_not_own, Promotion.moved_instance_variable(nil, given, self, :@x).reason
    assert_equal :holds_own_variable, Promotion.moved_instance_variable(own, given, self, :@x).reason
    assert_equal :not_given_variable, Promotion.moved_instance_variable(nil, 3, self, :@x).reason
  end

  def test_a_local_copies_what_the_game_changes_and_keeps_a_handle_as_it_is
    builder = Builder.new
    hp = builder.var(:hp, 0)

    assert_equal :copy_of_variable_read_whole, Promotion.copy(hp, :every_variable).reason
    assert_equal :handle_read_live, Promotion.copy(hp, :numbers).reason
    assert_equal :copy_of_number_in_ruby, Promotion.copy(builder.hidden_variable(:promoted), :numbers).reason
    assert_equal :copy_of_changing_working_out, Promotion.copy(hp + 1, :numbers).reason
    assert_equal :copy_of_test_answer, Promotion.copy(hp > 1, :numbers).reason
    assert_equal :plain_ruby_value, Promotion.copy(3, :numbers).reason
  end
end
