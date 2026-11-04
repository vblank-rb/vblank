# frozen_string_literal: true

require "test_helper"

# What a cartridge lowering holds while it makes a routine, put back after a routine found too big
# for a bank (LoweringState#snapshot), or measured on copies (LoweringState#on_copies). Shared by the
# cartridge lowerings and playing no game, so its tests are with the Color's, beside RoutineCuts'.
class TestLoweringState < Minitest::Test
  # Something a lowering changes the insides of as it makes a statement: its memory, its art.
  class Gathered
    attr_reader :rows, :named

    def initialize(rows, named)
      @rows = rows
      @named = named
    end
  end

  # A lowering's state: a table of its own, a Gathered holding an inner list that the table also
  # holds, and a number.
  class Lowering
    attr_reader :table, :gathered, :count

    def initialize
      @shared_row = [1, 2]
      @table = { first: @shared_row }
      @gathered = Gathered.new([@shared_row], { a: 1 })
      @count = 0
    end

    def make_a_routine
      @shared_row << 3
      @table[:second] = []
      @gathered.rows << [9]
      @gathered.named[:b] = 2
      @count += 1
      @made_later = true
    end
  end

  STATE = VBlank::IR::Backends::LoweringState.new(copied: [Gathered], shared: [Integer], unchanged: [])

  def test_restore_puts_every_object_back_as_it_was
    lowering = Lowering.new
    before = STATE.snapshot(lowering)
    lowering.make_a_routine
    before.restore!

    assert_equal({ first: [1, 2] }, lowering.table)
    assert_equal [[1, 2]], lowering.gathered.rows
    assert_equal({ a: 1 }, lowering.gathered.named)
    assert_equal 0, lowering.count
    refute lowering.instance_variable_defined?(:@made_later)
  end

  # Nothing is swapped for a copy: a list the table and the Gathered both hold is one list after.
  def test_restore_keeps_a_list_held_in_two_places_one_list
    lowering = Lowering.new
    gathered = lowering.gathered
    before = STATE.snapshot(lowering)
    lowering.make_a_routine
    before.restore!

    assert_same gathered, lowering.gathered
    assert_same lowering.table[:first], lowering.gathered.rows.first
    lowering.table[:first] << 7
    assert_equal [1, 2, 7], lowering.gathered.rows.first
  end

  def test_a_measurement_on_copies_leaves_the_lowering_as_it_was_and_one_list_held_twice_one_copy
    lowering = Lowering.new
    together = STATE.on_copies(lowering) do
      lowering.make_a_routine
      lowering.instance_variable_get(:@shared_row).equal?(lowering.gathered.rows.first)
    end

    assert together
    assert_equal({ first: [1, 2] }, lowering.table)
    assert_equal [[1, 2]], lowering.gathered.rows
  end

  def test_a_lowering_holding_what_the_state_does_not_know_is_refused
    lowering = Lowering.new
    lowering.instance_variable_set(:@unknown, Object.new)

    error = assert_raises(ArgumentError) { STATE.snapshot(lowering) }
    assert_match(/neither copies nor shares/, error.message)
  end
end
