# frozen_string_literal: true

require "test_helper"
require "compared_without_advance_emulator"

# Two Genesis cartridges compared with only the Genesis's emulator to play them in
# (ComparedWithoutAdvanceEmulator).
class TestComparisonWithoutTheAdvanceEmulatorOnTheGenesis < Minitest::Test
  # It starts a child process, which hangs inside a Ractor.
  runs_on_the_main_ractor!

  include ComparedWithoutAdvanceEmulator

  def test_two_genesis_cartridges_are_compared_without_the_advance_s_emulator
    assert_compared_without_advance_emulator(:genesis, columns: 40)
  end
end
