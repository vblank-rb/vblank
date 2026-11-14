# frozen_string_literal: true

require "test_helper"
require "stringio"

# A CALL OF A ROUTINE IN THE CALLER'S OWN BANK, on the Color. Only a call into another bank must
# go through the runtime's far call, which puts the routine's bank in view and the caller's back
# after (Runtime::Calls); a routine already in view is called with a plain CALL, as the console's
# own games call within a bank. Which bank each routine lands in is known only once the linker has
# placed them all, so the choice is made there (Linker#patch).
class TestGBCNearCalls < Minitest::Test
  CALLS_A_PASS = 24

  # A game whose loop calls three small routines CALLS_A_PASS times a pass, all small enough to
  # share a bank with the loop.
  private def many_calls
    VBlank.game("NEAR CALLS", consoles: %i[gbc]) do
      count = var :count, 0
      step = var :step, 0
      func(:bump) { count += 1 }
      func(:turn) { step = (step + 3) & 63 }
      func(:both) do
        call :bump
        call :turn
      end
      game_loop do
        (TestGBCNearCalls::CALLS_A_PASS / 3).times do
          call :bump
          call :turn
        end
        (TestGBCNearCalls::CALLS_A_PASS / 6).times { call :both }
      end
    end
  end

  private def profile(game)
    game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 30)
  end

  # What is left is the runtime's own call of the game loop, once a pass from the part always in
  # view, which is not in any routine's bank.
  def test_a_call_within_a_bank_does_not_go_through_the_far_call
    spent = profile(many_calls).runtime.to_h { |row| [row.routine, row.share] }
    far = spent.fetch("rt_far_call", 0) + spent.fetch("rt_far_call_de", 0) + spent.fetch("rt_jump_hl", 0)

    assert_operator far, :<, 0.002, "the far call takes #{(far * 100).round(2)}% of the frame"
  end

  def test_the_calls_give_the_interpreters_numbers
    game_player.run(many_calls.program(console: :gbc), frames: 8)
  end

  GBC = VBlank::IR::Backends::GBC
  CALL = 0xCD

  # A caller in a bank of its own and two routines: one that shares the caller's bank, one too big
  # to, which the linker puts in the next.
  private def linked_calls
    far_call = GBC::SM83.new("runtime", home: :fixed)
    far_call.label(GBC::SM83::FAR_CALL)
    far_call.ret
    caller = GBC::SM83.new("caller")
    caller.label("caller")
    caller.call_banked("near")
    caller.call_banked("far")
    caller.ret
    near = GBC::SM83.new("near")
    near.label("near")
    near.ret
    far = GBC::SM83.new("far")
    far.label("far")
    far.data_bytes(Array.new(GBC::Linker::BANK_SIZE - 4, 0))
    GBC::Linker.new([far_call, caller, near, far].map(&:section)).link
  end

  # A section of +bytes+ named +name+, calling each of +calls+.
  private def routine(name, bytes, calls: [])
    asm = GBC::SM83.new(name)
    asm.label(name)
    calls.each { |label| asm.call_banked(label) }
    asm.data_bytes(Array.new(bytes, 0))
    asm.ret
    asm.section
  end

  # A small routine that first fit would put in the first bank, beside something it has nothing to
  # do with, goes in the bank of the routine that calls it, where there is room too.
  def test_the_linker_places_a_routine_in_its_callers_bank_where_it_fits
    far_call = GBC::SM83.new("runtime", home: :fixed)
    far_call.label(GBC::SM83::FAR_CALL)
    far_call.ret
    sections = [far_call.section, routine("filler", GBC::Linker::BANK_SIZE - 50),
                routine("caller", GBC::Linker::BANK_SIZE - 100, calls: ["small"]), routine("small", 20)]
    linked = GBC::Linker.new(sections).link

    refute_equal linked.bank_of("filler"), linked.bank_of("caller")
    assert_equal linked.bank_of("caller"), linked.bank_of("small")
  end

  def test_the_linker_calls_a_routine_in_the_callers_bank_directly_and_another_bank_far
    linked = linked_calls
    bank = linked.banks[linked.bank_of("caller")]
    at = linked.address_of("caller") - GBC::Linker::BANKED_START
    near = linked.address_of("near")
    far_call = linked.address_of(GBC::SM83::FAR_CALL)

    assert_equal linked.bank_of("caller"), linked.bank_of("near")
    refute_equal linked.bank_of("caller"), linked.bank_of("far")
    assert_equal [CALL, near & 0xFF, near >> 8, 0, 0, 0], bank.byteslice(at, 6).bytes
    assert_equal [CALL, far_call & 0xFF, far_call >> 8, linked.bank_of("far")], bank.byteslice(at + 6, 4).bytes
  end
end
