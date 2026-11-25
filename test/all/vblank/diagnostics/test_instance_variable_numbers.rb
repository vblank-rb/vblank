# frozen_string_literal: true

require "test_helper"
require "stringio"

# The report of numbers kept in instance variables (Diagnostics::InstanceVariableNumbers): each
# with the name a profile and a test read it by.
class TestInstanceVariableNumbers < Minitest::Test
  REPORT = VBlank::Diagnostics::InstanceVariableNumbers

  private def rendered(rom)
    out = StringIO.new
    REPORT.render(rom, VBlank::IR::Printer.for(out, color: false))
    out.string
  end

  def test_a_number_counted_by_game_code_is_told_by_its_name
    rom = VBlank.build("COUNTED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      @score = 0
      game_loop { @score += 1 }
    end

    assert_includes rendered(rom), "score  @score of the game block"
  end

  # Read in the loop before the line that changes it.
  def test_a_number_read_before_it_is_changed_is_told_too
    rom = VBlank.build("READ", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      @score = 0
      shown = 0
      game_loop do
        shown = @score
        @score += 5 if shown < 100
      end
    end

    assert_equal ["score"], REPORT.as_json(rom)[:instance_variables].map { |each| each[:name].to_s }
  end

  def test_a_game_with_none_tells_nothing
    rom = VBlank.build("NONE", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop { clear_screen :black }
    end

    assert_empty rendered(rom)
  end
end
