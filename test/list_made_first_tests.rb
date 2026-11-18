# frozen_string_literal: true

# A LIST READ OR WRITTEN BEFORE IT IS MADE, played on a cartridge console's own build alone, not
# beside the interpreter, which would stop first and hide what the cartridge does. The interpreter
# stops the game there (the list holds nothing until it is made), and so must the cartridge, even
# for a list made full and never resized, whose index a build tests against its capacity or not at
# all (IR::Backends::LoweringPlan#lists_made_before_use). Each console's test includes this and
# names its build's headless run as +cartridge_run+.
module ListMadeFirstTests
  B = VBlank::IR::Build

  # Each way a step reaches a list before it is made, with the index it reaches.
  EARLY_STEPS = {
    "a write at a number" => -> { [B.list_set(:early, B.int(1), B.int(7))] },
    "a read at a variable" => -> { [B.set(:at, 1), B.set(:got, B.list_get(:early, B.var_ref(:at)))] },
    "a read at a number" => -> { [B.set(:got, B.list_get(:early, B.int(1)))] },
    "a read at a mask" => -> { [B.set(:at, 9), B.set(:got, B.list_get(:early, B.binop(:&, B.var_ref(:at), B.int(3))))] },
  }.freeze

  def test_a_full_list_reached_before_it_is_made_stops_the_cartridge
    EARLY_STEPS.each do |how, steps|
      program = B.program(*steps.call, B.list_new(:early, 4, full_of: 0), B.halt)
      err = assert_raises(VBlank::IR::ProgramError, how) { cartridge_run.run(program, frames: 3) }
      assert_match(/out of range/i, err.message, how)
    end
  end

  # ...and made first, it holds its capacity: a read at a number inside it reads the slot.
  def test_a_full_list_made_first_reads_its_slot
    program = B.program(B.list_new(:early, 4, full_of: 5), B.set(:at, 9),
                        B.set(:got, B.list_get(:early, B.binop(:&, B.var_ref(:at), B.int(3)))),
                        B.set(:seen, B.list_get(:early, B.int(2))), B.halt)
    run = cartridge_run.run(program, frames: 3)

    assert_equal [5, 5], [run[:got], run[:seen]]
  end
end
