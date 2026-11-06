# frozen_string_literal: true

require "test_helper"

# A PROGRAM IS LAID OUT FOR THE CONSOLE IT NAMES. The library assumes none, so one that names none
# stops and says how to name one. Only the test kit stands in front of that
# (Testing::LaidOutForTheAdvance).
class TestProgramNamesAConsole < Minitest::Test
  def test_a_program_naming_a_console_is_laid_out_for_it
    assert_equal :gbc, VBlank::IR::Build.program(console: :gbc).described_console.name
  end

  # What the library does with no test kit in the way: the method the kit stands in front of.
  def test_with_no_test_kit_a_program_naming_no_console_says_how_to_name_one
    library_answer = VBlank::IR::Nodes::Program.instance_method(:console_description).super_method
    error = assert_raises(VBlank::BuildError) { library_answer.bind_call(VBlank::IR::Build.program) }

    assert_match(/names no console/, error.message)
    assert_match(/To fix this/, error.message)
  end
end
