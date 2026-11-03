# frozen_string_literal: true

require "test_helper"

# A sprite shown over a painted screen (`sprite ..., over_picture: true`) needs the console's sprite
# layer on there, so a game with one has painted screens only.
class TestIRGuardrailSpriteOverPictureBesideTiles < Minitest::Test
  Guardrails = VBlank::IR::Guardrails

  private def validator = Guardrails::Validator.new(checks: [Guardrails::Checks::SpriteOverPictureBesideTiles.new])

  # A painted game with a gun over its picture, in a scene of its own, and a second scene on a
  # screen of +map_screen+.
  private def gun_program(map_screen:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :bitmap
      image(:gun, "#" => :white) { "########\n" * 8 }
      var :state, 0
      scene(:play) do
        screen :bitmap
        sprite :gun, at: [100, 100], over_picture: true
        clear_screen :black
      end
      scene(:map) { screen map_screen }
      game_loop do
        case_var :state do
          when_val 0, :play
          when_val 1, :map
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def refusal(program) = validator.run(program, autofix: false).errors.first&.message

  def test_a_sprite_over_a_painted_screen_beside_another_painted_one_is_fine
    assert_nil refusal(gun_program(map_screen: :bitmap))
  end

  def test_a_sprite_over_a_painted_screen_beside_a_tiled_scene_is_refused
    program = gun_program(map_screen: :tiled)

    assert_match(/sprite :gun is shown over_picture: true.*also has a tiled screen/, refusal(program))
  end

  def test_the_interpreter_refuses_it_too
    program = gun_program(map_screen: :tiled)

    error = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(program, frames: 2) }
    assert_match(/painted screens only/, error.message)
  end
end
