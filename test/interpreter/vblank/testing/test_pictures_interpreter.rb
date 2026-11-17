# frozen_string_literal: true

require "test_helper"

# The picture check a game includes from the library's test helper (VBlank::Testing::Pictures),
# where it differs from what this suite already holds it to through Differential: what a game's
# test sees when the emulator is not there.
#
# Only the run whose player is the interpreter asks the emulator here: every other run's player is
# its own lowered game, which needs none. So this is the interpreter's run's alone.
class TestPicturesInterpreter < Minitest::Test
  # Swaps the emulator's loader for one that cannot find it, which is the whole process's, so it
  # cannot run beside tests in other Ractors that need the real one.
  runs_on_the_main_ractor!

  include VBlank::Testing::Pictures

  # A GAME WITHOUT THE EMULATOR GEM gets a failed test that says what to put in its Gemfile, not an
  # error from inside the library with a backtrace through it.
  def test_without_the_emulator_the_check_fails_saying_what_to_add
    advice = VBlank::Diagnostics::MissingEmulator.new(detail: "cannot load such file -- ruby_gba_emulator",
                                                      bundled: false).advice
    program = VBlank.game("NOEMU", consoles: %i[gba]) do
      screen :bitmap
      game_loop { pixel 10, 10, :red }
    end.program

    err = without_the_emulator(advice) do
      assert_raises(Minitest::Assertion) { assert_backends_agree(program, frames: 2) }
    end
    assert_match(/Put this in your Gemfile/, err.message)
    assert_match(/gem "ruby-gba-emulator"/, err.message)
  end

  private

  # Run the block with the emulator's loader raising +advice+ as a missing emulator does, and put
  # the real loader back after, by name: a method defined again from another method's handle could
  # not be called from any other Ractor for the rest of the run.
  #
  # The stand-in raises only on the main Ractor. The workers playing the other files run beside
  # this class, and one that loads the emulator while it is in place is handed the real loader; a
  # stand-in made from a block nobody made shareable would stop it with "defined with an
  # un-shareable Proc in a different Ractor".
  def without_the_emulator(advice)
    emulator = VBlank::Diagnostics::Emulator
    emulator.singleton_class.alias_method(:__real_load!, :load!)
    emulator.singleton_class.remove_method(:load!)
    emulator.define_singleton_method(:load!, MissingLoader.stand_in(advice.dup.freeze))
    yield
  ensure
    emulator.singleton_class.remove_method(:load!)
    emulator.singleton_class.alias_method(:load!, :__real_load!)
    emulator.singleton_class.remove_method(:__real_load!)
  end

  # The stand-in #without_the_emulator gives the loader, made in a module so the block's self is
  # one every Ractor may share.
  module MissingLoader
    module_function

    def stand_in(advice)
      Ractor.make_shareable(lambda do
        raise LoadError, advice if Ractor.main?

        VBlank::Diagnostics::Emulator.__real_load!
      end)
    end
  end
end
