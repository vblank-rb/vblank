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
  # runtime lacks is a gap named in the refusal, never a Haxe error found by compiling; and a gap is a function the
  # JavaScript runtime defines (or a feature of the runtime), or it is a mistake of the lowering, not a part to port.
  def test_every_function_the_fixture_calls_is_defined_or_named_as_a_gap_the_javascript_runtime_has
    program = ConformanceFixture.program
    lowering = Flash::Lowering.new(program)
    _text, gaps = VBlank::Testing::BuildChecks.without_checks { lowering.text_and_gaps(Flash::HEADLESS_FUNCTIONS) }
    javascript = VBlank::IR::Backends::JS::RUNTIME.map { |file| File.read(File.join(VBlank::IR::Backends::JS::RUNTIME_DIR, file)) }.join +
                 VBlank::IR::Backends::RuntimeFeatures.js_text(VBlank::IR::Backends::RuntimeFeatures::ALL)
    defined_in_javascript = javascript.scan(/^function\*? (\w+)\(/).flatten
    features = VBlank::IR::Backends::RuntimeFeatures::ALL.map { |feature| "the #{feature.name} feature" }
    unknown = gaps.reject { |gap| defined_in_javascript.include?(gap) || features.include?(gap) }

    assert_empty unknown
    assert_empty(gaps.select { |gap| Flash::HEADLESS_FUNCTIONS.include?(gap) }, "a function the runtime defines is no gap")
  end

  # Every form of statement the shared lowering can build has a place in the Haxe printer, or is a part of the file
  # the printer leaves out on purpose.
  def test_the_printer_has_a_form_for_every_statement
    source = File.read(File.join(File.dirname(Flash::Lowering.instance_method(:text_and_gaps).source_location.first), "printer.rb"))
    forms = VBlank::IR::Backends::Computer::Statements.constants.map(&:to_s)
    c_alone = %w[Struct ConstGlobal] # a struct and a pointer, which no lowering for a computer but C's builds (the JavaScript printer has none either)
    unprinted = forms.reject { |form| c_alone.include?(form) || source.include?("Statements::#{form}") }

    assert_empty unprinted
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

  # A function the runtime does not define is a gap named in the refusal, so a game that needs one is never built.
  def test_a_game_that_needs_a_function_the_runtime_lacks_is_refused_by_it
    game = VBlank.game("beeper", consoles: %i[gba]) do
      enable_sound
      game_loop do
        beep :blip
      end
    end
    program = VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new)
    _text, gaps = Flash::Lowering.new(program).text_and_gaps(Flash::HEADLESS_FUNCTIONS - ["rg_sound_beep"])

    assert_includes gaps, "rg_sound_beep"
  end

  # The sound chip of a console whose voices read sound memory is not worked out, so a game that makes sound there is
  # refused by name; a game of that console that makes none is not.
  def test_a_game_that_makes_sound_on_a_sound_memory_console_is_refused_by_the_chip
    game = VBlank.game("beeper", consoles: %i[ps1]) do
      enable_sound
      game_loop do
        beep :blip
      end
    end
    program = VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :ps1, err: StringIO.new)
    error = assert_raises(Flash::RuntimeGap) { Flash.new.build_headless(program) }

    assert_equal "the sound chip that reads sound memory", error.part
  end
end
