# frozen_string_literal: true

require "test_helper"
require "background_switch_tests"

# A background switched off and on again, on the Advance: the tests every console that can leave a
# layer out plays (BackgroundSwitchTests in test/background_switch_tests.rb), and one of the
# Advance's own. Its display switches each layer on and off with a bit of its display control
# register, so a hidden background takes none of the display's windows, which a light needs.
class TestBackgroundSwitch < Minitest::Test
  include BackgroundSwitchTests

  def test_a_hidden_background_and_a_light_share_one_screen
    game = switched_game do |sword, passes|
      spotlight at: [120, 80], radius: 40, dark: 100
      sword.hide if passes == 5
      sword.show if passes == 10
    end

    assert_equal RED, game_player.run(game, frames: 3).screen.pixel(120, 80), "before hide, in the light"
    assert_equal GREEN, game_player.run(game, frames: 8).screen.pixel(120, 80), "after hide, in the light"
    assert_equal RED, game_player.run(game, frames: 14).screen.pixel(120, 80), "after show, in the light"
    assert_backends_agree(game, frames: [3, 8, 14], name: "SWITCHLT")
  end

  # A hidden background every turning screen shows, across a painted screen: coming back, the
  # display's settings are written whole as the turning screen is entered, and the hidden layer
  # stays out of them until the background is put back, as the interpreter shows it.
  def test_a_hidden_background_stays_hidden_across_a_painted_screen
    b = Builder.new
    b.instance_eval do
      screen :rotozoom
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :front_set, "#" => :red_tile
      sword = background :sword, tiles: :front_set, map: Array.new(16) { "#" * 16 }
      state = 0
      tick = 0
      scene(:field) { state = 1 if tick == 5 }
      scene(:painted) do
        screen :bitmap
        clear_screen :blue
        state = 0 if tick == 9
      end
      game_loop do
        tick += 1
        sword.hide
        case_var(:state) do
          when_val 0, :field
          when_val 1, :painted
        end
      end
    end
    b.finalize_program

    # The interpreter's pictures: the screen comes back with the layer still off, then the
    # background is put back as declared, shown for one picture as a box is set aside, and the
    # `hide` said again in that pass takes it off from the next.
    seen = (10..14).map { |frame| game_player.run(b.program, frames: frame).screen.pixel(120, 80) == RED }

    assert_equal [false, true, false, false, false], seen, "frames 10 to 14, red or not"
    (10..14).each { |frame| assert_backends_agree(b.program, frames: frame, console_frames: frame + 1, name: "SWITCHBM") }
  end

  # The same as a build for the Advance, whose checks refuse a box beside a light.
  def test_the_build_takes_a_hidden_background_beside_a_light
    rom = VBlank.build("SWITCHLT", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      sword = background :sword, tiles: :set, map: ["#" * 8]
      passes = var :passes, 0
      game_loop do
        passes += 1
        spotlight at: [120, 80], radius: 40, dark: 100
        sword.hide if passes == 5
      end
    end

    assert_kind_of ROM, rom
  end
end
