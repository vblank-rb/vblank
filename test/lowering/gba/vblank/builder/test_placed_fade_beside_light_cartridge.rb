# frozen_string_literal: true

require "test_helper"
require "differential"

# A game with a light that fades under a layer in a scene the light is off in, on the Advance's
# cartridge. The fade keeps the sprites in front of it out with the display's object window, and
# the light is the display's first window, which wins over the object window wherever the two
# overlap. So in a scene the light is off in, the light's window has to be shut, or every sprite
# it covers is faded with the room. Each game is held to the interpreter, every pixel.
class TestPlacedFadeBesideLightCartridge < Minitest::Test
  include Differential

  # The turn the title hands over to the lit scene on, and the turn it takes over again.
  LIT_ON = 8
  BACK_ON = 30

  # A white room, a green sprite in the room's layer and a red sprite in the pond's layer in front
  # of it. The title fades half way to black under the pond's layer: the room and the green sprite
  # fade, the red sprite does not. The lit scene closes a circle round the middle of the room
  # (+outside+ is the light's), and the title takes over again after it.
  private def kept_sprite_game(outside: :darkened)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:green_guy, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      layer(:ground) { sprite :faded, image: :green_guy, at: [100, 76] }
      layer(:water) { sprite :kept, image: :red_guy, at: [132, 76] }
      spotlight outside: outside if outside == :nothing
      mode = var :mode, 0
      turn = var :turn, 0
      scene(:title) { fade :black, 50, under: :water }
      scene(:lit) { iris_out from: 150, by: 8 if turn == LIT_ON }
      game_loop do
        turn += 1
        mode.store!(1) if turn == LIT_ON
        mode.store!(0) if turn == BACK_ON
        call({ 0 => :title, 1 => :lit }, number: :mode)
      end
    end
    builder.finalize_program
    builder.program
  end

  # In the title, round the hand over, with the circle round both sprites, with it closed small
  # enough to leave the kept sprite outside it, and round the title taking over again.
  FRAMES = [3, LIT_ON - 1, LIT_ON, LIT_ON + 1, LIT_ON + 4, LIT_ON + 17, BACK_ON, BACK_ON + 1, BACK_ON + 4].freeze

  def test_the_cartridge_keeps_the_sprite_out_of_the_fade_beside_a_darkening_light
    assert_backends_agree(kept_sprite_game, frames: FRAMES, name: "KEPTLIGHT")
  end

  def test_the_cartridge_keeps_the_sprite_out_of_the_fade_beside_a_light_showing_nothing_outside
    assert_backends_agree(kept_sprite_game(outside: :nothing), frames: FRAMES, name: "KEPTSHUT")
  end
end
