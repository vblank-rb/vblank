# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# What the Flash runtime cannot do yet is refused by name before a game is played, and a game it can play is not
# refused. Which kinds are written at all is the shared lowering's to say (Flash::Lowering inherits its tables, and
# test_native_kind_coverage.rb holds them); what only this lowering can get wrong is a runtime with a function
# missing, or one defined twice.
class TestFlashKindCoverage < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  def test_no_runtime_function_is_defined_twice
    names = Flash::RUNTIME.map { |file| File.read(File.join(Flash::RUNTIME_DIR, file)).scan(/^static (?:inline )?function (\w+)/).flatten }.flatten

    assert_empty names.tally.select { |_, count| count > 1 }.keys
  end

  # The kitchen-sink fixture touches every kind, so its Haxe calls everything a game can call. A function the
  # runtime lacks is a gap named in the refusal, never a Haxe error found by compiling.
  def test_every_function_the_fixture_calls_is_defined_or_named_as_a_gap
    program = ConformanceFixture.program
    lowering = Flash::Lowering.new(program)
    _text, gaps = VBlank::Testing::BuildChecks.without_checks { lowering.text_and_gaps(Flash::HEADLESS_FUNCTIONS) }
    unnamed = gaps.reject { |gap| gap.start_with?("rg_") || gap.start_with?("the ") }

    assert_empty unnamed
    assert_empty(gaps.select { |gap| Flash::HEADLESS_FUNCTIONS.include?(gap) }, "a function the runtime defines is no gap")
  end

  def test_a_game_the_runtime_can_play_has_no_gap
    game = VBlank.game("small", consoles: %i[gba]) do
      x = var :x, 1
      game_loop do
        clear_screen :black
        fill_rect x, 3, 2, 2, :red
        x.increase!(1)
      end
    end
    program = VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new)
    _text, gaps = Flash::Lowering.new(program).text_and_gaps(Flash::HEADLESS_FUNCTIONS)

    assert_empty gaps
  end

  def test_a_game_that_beeps_is_refused_by_the_function_it_needs
    game = VBlank.game("beeper", consoles: %i[gba]) do
      enable_sound
      game_loop do
        beep :blip
      end
    end
    program = VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new)
    error = assert_raises(Flash::RuntimeGap) { Flash.new.build_headless(program) }

    assert_match(/\Arg_sound_/, error.part)
    assert_includes error.message, "rg_sound_beep"
  end
end
