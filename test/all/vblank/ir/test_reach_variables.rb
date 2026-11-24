# frozen_string_literal: true

require "test_helper"

# A lowering that keeps a loop's count in a register leans on Reach::VARIABLES_OF to know which
# statements write a variable. A kind that writes one and is missing there would be taken for a
# reader, and the loop would count on while something else changed its number. The interpreter
# is the answer key for what a kind writes: each `exec_<kind>` that assigns into `@vars` names a
# kind that must be listed.
class TestReachVariables < Minitest::Test
  REFERENCE = VBlank.root.join("lib", "vblank", "ir", "backends").to_s

  # Kinds that write only variables of the framework's own, which no game names: setting the clock
  # writes where its offset from the console's clock is kept (IR::Clock::OFFSET_DAYS and the rest).
  FRAMEWORK_ONLY = %i[set_clock].freeze

  # Every kind whose interpreter method assigns a variable.
  private def kinds_writing_variables
    Dir.glob("#{REFERENCE}/reference.rb").concat(Dir.glob("#{REFERENCE}/reference/**/*.rb")).flat_map do |path|
      File.read(path).split(/^\s*def (?=exec_)/).drop(1).filter_map do |method|
        kind = method[/\Aexec_(\w+)/, 1]
        body = method.split(/^\s*def /).first
        kind.to_sym if body.match?(/@vars\[[^\]]+\]\s*(?:\+|-)?=(?!=)/)
      end
    end.uniq
  end

  def test_every_kind_the_interpreter_writes_a_variable_with_is_listed
    unlisted = kinds_writing_variables - FRAMEWORK_ONLY - VBlank::IR::Reach::VARIABLES_OF.keys

    assert_empty unlisted, "these statements write a variable but Reach::VARIABLES_OF does not name it"
  end

  def test_the_scan_finds_the_kinds_it_is_meant_to
    assert_includes kinds_writing_variables, :add
    assert_includes kinds_writing_variables, :list_pack
    assert_includes kinds_writing_variables, :save_init
  end
end
