# frozen_string_literal: true

# A BACKGROUND SWITCHED OFF AND ON AGAIN AS THE GAME RUNS (`hide` and `show`), on every console
# whose display can leave a layer out. The Color and the Genesis refuse it
# (test/all/vblank/dsl/test_background_switch_refusals.rb). Each console that can has a test file in
# its folder that includes these, so they are written once and played on every run that plays
# games as that console:
#
#   test/console/gba/vblank/dsl/test_background_switch.rb
#   test/console/snes/vblank/dsl/test_background_switch_on_the_super_nintendo.rb
#   test/console/ps1/vblank/dsl/test_background_switch_on_the_playstation.rb
#
# The games stack a red background in front of a green one that fills the screen, so a pixel says
# which of the two the display drew there: red while the front one shows, green while it is off.
require "differential"

module BackgroundSwitchTests
  include SharedConstants
  include Differential

  RED = 0x001F
  GREEN = 0x03E0

  # A screen of green, and in front of it a screen of red. The block is the game loop's body,
  # handed the red background's handle and a count of the passes, 1 on the first.
  private def switched_game(&body)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :front_set, "#" => :red_tile
      passes = var :passes, 0
      layers :back, :front
      layer(:back) { background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      layer :front do
        sword = background :sword, tiles: :front_set, map: Array.new(32) { "#" * 32 }
        game_loop do
          passes += 1
          instance_exec(sword, passes, &body)
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Off from the fifth pass to the tenth, on before and after.
  private def off_for_a_stretch
    switched_game do |sword, passes|
      sword.hide if passes == 5
      sword.show if passes == 10
    end
  end

  def test_a_hidden_background_shows_what_is_behind_it_until_it_is_shown_again
    assert_equal RED, game_player.run(off_for_a_stretch, frames: 3).screen.pixel(120, 80), "before hide"
    assert_equal GREEN, game_player.run(off_for_a_stretch, frames: 8).screen.pixel(120, 80), "after hide"
    assert_equal GREEN, game_player.run(off_for_a_stretch, frames: 8).screen.pixel(0, 0), "after hide, the corner"
    assert_equal RED, game_player.run(off_for_a_stretch, frames: 14).screen.pixel(120, 80), "after show"
  end

  def test_hide_said_every_pass_keeps_it_hidden
    game = switched_game { |sword, _| sword.hide }

    assert_equal GREEN, game_player.run(game, frames: 6).screen.pixel(239, 159)
  end

  # Every pixel of the picture, before, during and after: on the run that plays the interpreter,
  # the console's cartridge read in the emulator; on any other, that run's own build.
  def test_the_console_draws_the_same_picture_as_the_background_goes_off_and_on
    assert_backends_agree(off_for_a_stretch, frames: [3, 5, 6, 8, 10, 11, 14], name: "SWITCH")
  end

  # Hidden in one scene, then a scene of its own comes up and goes again: the background comes
  # back shown, as a box is set aside, until the scene hides it again.
  def test_a_scene_taking_over_shows_its_background_again
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :front_set, "#" => :red_tile
      state = var :state, 0
      passes = var :passes, 0
      layers :back, :front
      layer(:back) { background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      scene(:hidden) do
        layer :front do
          sword = background :sword, tiles: :front_set, map: Array.new(32) { "#" * 32 }
          sword.hide if passes < 6
        end
      end
      scene(:away) { nil }
      game_loop do
        passes += 1
        state = 1 if passes == 6
        state = 0 if passes == 8
        case_var(:state) do
          when_val 0, :hidden
          when_val 1, :away
        end
      end
    end
    b.finalize_program

    assert_equal GREEN, game_player.run(b.program, frames: 4).screen.pixel(120, 80)
    assert_equal RED, game_player.run(b.program, frames: 14).screen.pixel(120, 80)
    assert_backends_agree(b.program, frames: [4, 7, 9, 14], name: "SWITCHSC")
  end
end
