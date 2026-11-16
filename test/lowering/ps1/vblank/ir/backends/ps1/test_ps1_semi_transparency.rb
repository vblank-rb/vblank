# frozen_string_literal: true

require "test_helper"

# The model of the PlayStation graphics chip's semi-transparency (PS1::SemiTransparency), which the
# PlayStation's checked run mixes a see-through layer with on the interpreter's side: each way's sums worked
# out by hand from psx-spx, and a picture where the model and the interpreter's own mix part, played in
# Beetle PSX. The chip mixes in five bits a channel and the interpreter widens to eight first, so on some
# pixels the two are a step apart: there the console's picture is the chip's, and the check holds it to
# the chip's rule, not let off.
class TestPS1SemiTransparency < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  Mix = PS1::SemiTransparency

  WHITE = 0x7FFF
  GREY_30 = 30 | (30 << 5) | (30 << 10)
  GREY_31_OVER_30_HALVED = GREY_30 # (31 + 30) / 2, the half dropped

  def test_each_way_the_chip_mixes
    under = 20 | (10 << 5) | (31 << 10)
    over = 12 | (31 << 5) | (6 << 10)

    assert_equal 16 | (20 << 5) | (18 << 10), Mix.mix(over, under, 8, 8), "half of each, the sum halved once"
    assert_equal 31 | (31 << 5) | (31 << 10), Mix.mix(over, under, 16, 16), "the two added, each stopping at 31"
    assert_equal 23 | (17 << 5) | (31 << 10), Mix.mix(over, under, 4, 16), "a quarter of the layer, its low bits dropped"
    assert_equal over, Mix.mix(over, under, 16, 0), "the layer whole"
  end

  # White over a grey of 30, half see-through: the chip halves 61 to 30 in each channel, where the
  # interpreter's own mix, widened to eight bits, comes to 31. The PlayStation's run shows the chip's.
  def test_the_playstation_shows_the_chips_mix_where_the_interpreters_own_is_a_step_brighter
    game = white_pane_over_grey

    assert_equal GREY_31_OVER_30_HALVED, game_player.run(game, frames: 2).screen.pixel(8, 8)
    assert_equal WHITE, Reference.new.run(game, frames: 2).screen.pixel(8, 8), "the interpreter's own mix"
  end

  # A see-through layer of sprites mixes with the scenery alone on the interpreter, never with a sprite
  # under it, which the chip's mix of whatever it drew first is not. The build does not make that yet.
  def test_a_see_through_layer_of_sprites_is_not_made_yet
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:ghost, "#" => :white) { SOLID_TILE }
      layers :spooks
      layer(:spooks, transparency: 50) { sprite :ghost, at: [64, 64] }
      game_loop { wait_vblank }
    end
    b.finalize_program
    program = b.program.copy.tap { |copy| copy.console = :ps1 }

    error = assert_raises(PS1::Lowering::NotMadeYet) { PS1.new.build(program) }
    assert_match(/sprites in a see-through layer/, error.message)
  end

  private def white_pane_over_grey
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:back, "#" => rgb(30, 30, 30)) { SOLID_TILE }
      image(:front, "#" => :white) { SOLID_TILE }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(32) { "#" * 32 } }
      layer(:glass, transparency: 50) { background :pane, tiles: :frontset, map: Array.new(32) { "#" * 32 } }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end
