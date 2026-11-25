# frozen_string_literal: true

require "test_helper"
require "pulled_tests"

# A gamepad's triggers part pulled, on the interpreter (PulledTests in test/pulled_tests.rb, which
# says why these are not in test/all/).
class TestPulledInterpreter < Minitest::Test
  include PulledTests

  # The same game built for the PlayStation's own pad reads a trigger all or nothing.
  def test_a_build_for_a_cartridge_reads_a_part_pull_all_or_nothing
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))
    builder.instance_eval do
      left = var :left, 0
      game_loop { left = pulled(:l2) }
    end
    builder.finalize_program

    assert_equal 100, Reference.new.hold(l2: 40).run(builder.program, frames: 3)[:left]
  end
end
