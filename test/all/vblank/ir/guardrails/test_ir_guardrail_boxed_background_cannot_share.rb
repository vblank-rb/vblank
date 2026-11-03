# frozen_string_literal: true

require "test_helper"

# What a background held to a box (`show_only_inside`) cannot share the display with. One box is one
# of the display's windows, so a screen holds one background to a box. On the Advance the light,
# a status bar and the fades held to part of the picture use the same windows.
class TestIRGuardrailBoxedBackgroundCannotShare < Minitest::Test
  Guardrails = VBlank::IR::Guardrails

  private def validator = Guardrails::Validator.new(checks: [Guardrails::Checks::BoxedBackgroundCannotShare.new])

  # A game on the Advance with a background held to a box, and whatever +more+ adds.
  private def boxed_program(&more)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :tiled
      image(:i_blue, "#" => :blue) { "########\n" * 8 }
      tiles :t, "#" => :i_blue
      dialogue = background :dialogue, tiles: :t, map: ["#" * 20]
      instance_eval(&more) if more
      game_loop { dialogue.show_only_inside 8, 8, 40, 40 }
    end
    b.finalize_program
    b.program
  end

  private def refusal(program) = validator.run(program, autofix: false).errors.first&.message

  def test_a_box_alone_is_fine
    assert_nil refusal(boxed_program)
  end

  def test_a_box_and_a_light_on_the_advance_are_refused
    program = boxed_program { spotlight at: [120, 80], radius: 30 }

    assert_match(/background :dialogue to a box.*a light/, refusal(program))
  end

  def test_a_box_and_a_status_bar_on_the_advance_are_refused
    program = boxed_program { status_bar :score, tiles: :t, map: ["#" * 20], top: 140 }

    assert_match(/the status bar :score/, refusal(program))
  end

  def test_two_backgrounds_held_to_boxes_on_one_screen_are_refused
    program = boxed_program do
      other = background :other, tiles: :t, map: ["#" * 20]
      other.show_only_inside 0, 0, 10, 10
    end

    assert_match(/:dialogue and :other are on the screen at the same time/, refusal(program))
  end
end
