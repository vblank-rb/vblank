# frozen_string_literal: true

require "test_helper"

# DOS IS A CONSOLE A GAME CAN NAME: its screen, its variants, `built_for?` and what the build refuses.
# These read the description and the answers through the DSL, so they need no DOS program to run.
class TestDOSConsole < Minitest::Test
  CHECK = VBlank::IR::Guardrails::Checks::ConsoleAnswers.new

  # A game that keeps the screen's size in two variables, which the interpreter then holds.
  SIZE = VBlank.game("SIZE", consoles: %i[gba dos]) do
    var :wide, screen_width
    var :high, screen_height
    var :here, built_for?(:dos) ? 1 : 0
    halt
  end

  private def size_of(**build)
    played = VBlank::IR::Backends::Reference.new.run(SIZE.program(console: :dos, **build), frames: 1)
    [played[:wide], played[:high]]
  end

  def test_a_game_can_name_dos
    assert_equal :dos, VBlank::Console.named("dos")
    assert_equal "DOS", VBlank::Console.described(:dos).title
  end

  def test_the_plain_screen_is_mode_13h
    assert_equal [320, 200], size_of
  end

  def test_each_variant_has_its_own_screen
    assert_equal [320, 240], size_of(variant: :mode_x)
    assert_equal [640, 480], size_of(variant: :vesa_640x480)
  end

  def test_built_for_answers_for_dos_and_for_a_variant
    played = VBlank::IR::Backends::Reference.new.run(SIZE.program(console: :dos), frames: 1)

    assert_equal 1, played[:here]
    assert_equal 0, VBlank::IR::Backends::Reference.new.run(SIZE.program(console: :gba), frames: 1)[:here]
  end

  def test_a_variant_dos_does_not_have_is_refused_naming_the_ones_it_has
    error = assert_raises(ArgumentError) { SIZE.program(console: :dos, variant: :turbo) }

    assert_match(/no variant named :turbo/, error.message)
    assert_match(/mode_x/, error.message)
  end

  def test_a_frame_is_one_retrace_at_about_70_hertz_and_60_in_the_taller_modes
    hertz = ->(variant) { 1 / VBlank::Console.described(:dos, variant: variant).frame_seconds.to_f }

    assert_in_delta 70.087, hertz.call(nil), 0.001
    assert_in_delta 59.94, hertz.call(:mode_x), 0.01
    assert_in_delta 59.94, hertz.call(:vesa_640x480), 0.01
  end

  def test_a_button_a_keyboard_does_not_stand_for_is_refused
    game = VBlank.game("XBUTTON", consoles: %i[gba dos]) do
      count = var :count, 0
      game_loop { count += 1 if held(:x) }
    end
    found = CHECK.detect(game.program(console: :dos))

    assert_equal [:error], found.map(&:severity)
    assert_match(/:x button/, found.first.message)
  end

  def test_every_verb_a_game_can_write_has_an_answer
    answered = VBlank::Console::DOSAnswers::ANSWERS.keys
    advance = VBlank::Console::PS1Answers::ANSWERS.keys

    assert_empty advance - answered
    assert_empty answered - advance
  end
end
