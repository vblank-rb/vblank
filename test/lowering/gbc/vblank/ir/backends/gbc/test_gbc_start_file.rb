# frozen_string_literal: true

require "test_helper"

# A cartridge holds its own data and is never handed a file as it starts (IR::StartFile), so the
# Color's lowering refuses a program that reads one, as a game built with its data pack left out
# does, in the words every cartridge lowering shares (LoweringPlan#refuse_start_file!).
class TestGBCStartFile < Minitest::Test
  def test_a_program_reading_a_file_as_it_starts_is_refused
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      clear_screen :black
      halt
    end
    b.finalize_program
    b.program.start_file = VBlank::IR::StartFile.new(called: "data pack", size: 64, checks: [])

    refused = assert_raises(VBlank::IR::Backends::GBC::LoweringError) { VBlank::IR::Backends::GBC.new.build(b.program) }

    assert_match "Game Boy Color cartridge holds", refused.message
  end
end
