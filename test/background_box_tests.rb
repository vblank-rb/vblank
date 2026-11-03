# frozen_string_literal: true

# A BACKGROUND SHOWN ONLY INSIDE A BOX THE GAME MOVES AND SIZES (`show_only_inside`), on every
# console whose display can hold a layer to a box. The Color and the Genesis cannot, and refuse it
# (test/all/vblank/dsl/test_background_box_refusals.rb). Each console that can has a test file in
# its folder that includes these, so they are written once and played on every run that plays
# games as that console:
#
#   test/console/gba/vblank/dsl/test_background_box.rb
#
# The games stack a red background in front of a green one that fills the screen, so a pixel says
# which of the two the display drew there: red inside the box, green, the layer behind, outside it.
require "differential"

module BackgroundBoxTests
  include SharedConstants
  include Differential

  RED = 0x001F
  GREEN = 0x03E0

  # A screen of green, and in front of it a screen of red held to a box. The block is the game
  # loop's body, handed the red background's handle.
  private def boxed_game(&body)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :box_set, "#" => :red_tile
      layers :back, :front
      layer(:back) { background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      layer :front do
        dialogue = background :dialogue, tiles: :box_set, map: Array.new(32) { "#" * 32 }
        game_loop { instance_exec(dialogue, &body) }
      end
    end
    b.finalize_program
    b.program
  end

  # A dialogue box that opens out from its middle, four rows a frame, to 64 rows: rows 48 to 111
  # once it is open, columns 40 to 199 all the while.
  private def opening_box
    boxed_game do |dialogue|
      tall = var :tall, 0
      tall += 4 if tall < 64
      dialogue.show_only_inside 40, 80 - (tall / 2), 160, tall
    end
  end

  def test_the_background_shows_inside_its_box_and_what_is_behind_shows_outside
    screen = game_player.run(opening_box, frames: 30).screen

    assert_equal RED, screen.pixel(120, 80)
    assert_equal RED, screen.pixel(40, 48)
    assert_equal RED, screen.pixel(199, 111)
    assert_equal GREEN, screen.pixel(39, 80), "left of the box"
    assert_equal GREEN, screen.pixel(200, 80), "right of the box"
    assert_equal GREEN, screen.pixel(120, 47), "above the box"
    assert_equal GREEN, screen.pixel(120, 112), "under the box"
  end

  def test_the_box_grows_as_the_game_makes_it_taller
    early = game_player.run(opening_box, frames: 6).screen

    assert_equal RED, early.pixel(120, 80)
    assert_equal GREEN, early.pixel(120, 52), "not open this far yet"

    late = game_player.run(opening_box, frames: 30).screen

    assert_equal RED, late.pixel(120, 52)
  end

  # Every pixel of the picture, as the box opens and once it is open: on the run that plays the
  # interpreter, the console's cartridge read in the emulator; on any other, that run's own build.
  def test_the_console_draws_the_same_picture_as_the_box_opens
    assert_backends_agree(opening_box, frames: [3, 8, 30], name: "BOX")
  end

  def test_the_console_draws_the_same_picture_with_a_box_past_the_edges_and_none
    assert_backends_agree(boxed_game { |dialogue| dialogue.show_only_inside(-50, 120, 400, 100) }, frames: 6, name: "BOXEDGE")
    assert_backends_agree(boxed_game { |dialogue| dialogue.show_only_inside(40, 40, 50, -3) }, frames: 6, name: "BOXNONE")
  end

  def test_a_box_past_the_screen_edges_is_the_part_on_the_screen
    game = boxed_game { |dialogue| dialogue.show_only_inside(-50, -50, 100, 100) }
    screen = game_player.run(game, frames: 4).screen

    assert_equal RED, screen.pixel(0, 0)
    assert_equal RED, screen.pixel(49, 49)
    assert_equal GREEN, screen.pixel(50, 10)
    assert_equal GREEN, screen.pixel(10, 50)
  end

  def test_a_box_of_no_width_shows_the_background_nowhere
    game = boxed_game { |dialogue| dialogue.show_only_inside(40, 40, 0, 50) }
    screen = game_player.run(game, frames: 4).screen

    assert_equal GREEN, screen.pixel(40, 40)
    assert_equal GREEN, screen.pixel(120, 80)
  end

  def test_show_everywhere_puts_the_whole_background_back
    game = boxed_game do |dialogue|
      passes = var :passes, 0
      passes += 1
      dialogue.show_only_inside 40, 40, 20, 20
      dialogue.show_everywhere if passes > 5
    end

    assert_equal GREEN, game_player.run(game, frames: 4).screen.pixel(120, 80)
    assert_equal RED, game_player.run(game, frames: 12).screen.pixel(120, 80)
  end

  # Held to a box in one scene, then a scene of its own comes up and goes again: the background
  # comes back showing everywhere, until the scene says a box again.
  def test_a_scene_taking_over_shows_its_background_everywhere_again
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :box_set, "#" => :red_tile
      state = var :state, 0
      passes = var :passes, 0
      layers :back, :front
      layer(:back) { background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      scene(:boxed) do
        layer :front do
          dialogue = background :dialogue, tiles: :box_set, map: Array.new(32) { "#" * 32 }
          dialogue.show_only_inside 0, 0, 10, 10 if passes < 6
        end
      end
      scene(:away) { nil }
      game_loop do
        passes += 1
        state = 1 if passes == 6
        state = 0 if passes == 8
        case_var(:state) do
          when_val 0, :boxed
          when_val 1, :away
        end
      end
    end
    b.finalize_program

    assert_equal GREEN, game_player.run(b.program, frames: 4).screen.pixel(120, 80)
    assert_equal RED, game_player.run(b.program, frames: 14).screen.pixel(120, 80)
  end
end
