# frozen_string_literal: true

require "test_helper"

# A cartridge holds its own data and is never handed a file as it starts (IR::StartFile), so the
# Advance's lowering refuses a program that reads one, as a game built with its data pack left out
# does, in plain words.
class TestGBAStartFile < Minitest::Test
  def test_a_program_reading_a_file_as_it_starts_is_refused
    b = Builder.new
    b.instance_eval do
      clear_screen :black
      halt
    end
    b.finalize_program
    b.program.start_file = VBlank::IR::StartFile.new(called: "data pack", size: 64, checks: [])

    refused = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }

    assert_match "cartridge holds", refused.message
    assert_match "all-in-one", refused.message
  end
end
