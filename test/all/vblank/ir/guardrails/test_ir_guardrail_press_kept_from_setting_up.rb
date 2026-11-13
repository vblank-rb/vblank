# frozen_string_literal: true

require "test_helper"
require "stringio"

# A NAME SET FROM A BUTTON WHILE THE GAME SETS UP, AND READ AS IT PLAYS. A Ruby local keeps the
# answer of its line, so the name holds the press of the moment the game started, which never
# changes. That is what the language says, and never what a game means by a press, so the build
# says, naming the line.
class TestIRGuardrailPressKeptFromSettingUp < Minitest::Test
  private def build_warnings(&game)
    err = StringIO.new
    VBlank.build("PRESSES", console: :gba, out: StringIO.new, err: err, &game)
    err.string
  end

  private def line_of(marker) = File.readlines(__FILE__).index { |line| line.include?(marker) } + 1

  def test_a_press_set_while_setting_up_and_read_in_a_routine_is_said
    said = build_warnings do
      advance = pressed(:a) | pressed(:b) # read in a routine
      seen = var :seen, 0
      func :read_press do
        seen = 1 if advance
      end
      game_loop { call :read_press }
    end

    assert_match(/`advance`/, said)
    assert_match(/test_ir_guardrail_press_kept_from_setting_up\.rb:#{line_of('# read in a routine')}/, said)
    assert_match(/where it is used/, said)
  end

  def test_a_held_button_set_while_setting_up_and_read_in_the_loop_is_said
    said = build_warnings do
      down = held(:left) # read in the loop
      seen = var :seen, 0
      game_loop { seen = 1 if down }
    end

    assert_match(/`down`/, said)
    assert_match(/:#{line_of('# read in the loop')}/, said)
  end

  # A button a game keeps as an object of its own, asked whether it was pressed.
  Button = Data.define(:name) do
    def pressed(game) = game.pressed(name)
  end

  def test_a_press_asked_of_the_games_own_button_objects_is_said
    err = StringIO.new
    game = VBlank.game("PRESSES", consoles: %i[gba], allow: %w[TestIRGuardrailPressKeptFromSettingUp::Button]) do
      buttons = [Button.new(:a), Button.new(:b)]
      advance = buttons.map { |button| button.pressed(self) }.reduce(:|)
      seen = var :seen, 0
      func(:read_press) { seen = 1 if advance }
      game_loop { call :read_press }
    end
    game.build_rom(out: StringIO.new, err: err, profile: false)

    assert_match(/`advance`.*where it is used/m, err.string)
  end

  def test_a_press_read_inside_the_routine_is_not_said
    said = build_warnings do
      seen = var :seen, 0
      func :read_press do
        advance = pressed(:a) | pressed(:b)
        seen = 1 if advance
      end
      game_loop { call :read_press }
    end

    refute_match(/where it is used/, said)
  end
end
