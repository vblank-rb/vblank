# frozen_string_literal: true

require "test_helper"

# EACH SCREEN SAYS WHAT SIZE ITS TILES ARE. The console has one setting for each layer, so it is
# told as a scene takes over, beside the scene's art: a title of 16×16 tiles and a stage of 16×16
# cells under a status bar of 8×8. The checked run compares the pictures on every pass.
class TestSNESTileSizesByScene < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  BIG = ((["..##" * 4] * 8) + (["##.." * 4] * 8)).join("\n").freeze
  SMALL = (["##.."  * 2] * 8).join("\n").freeze

  private def game(&stage)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:big, "#" => :white, "." => :blue) { BIG }
      image(:small, "#" => :red, "." => :green) { SMALL }
      tiles :large, "#" => :big
      tiles :little, "#" => :small
      state = var :state, 0
      step = 0
      scene(:title) { background :logo, tiles: :large, map: Array.new(8) { "#" * 8 } }
      scene(:stage) { instance_exec(&stage) }
      game_loop do
        step += 1
        state = 1 if step == 8
        state = 0 if step == 16
        case_var(:state) do
          when_val 0, :title
          when_val 1, :stage
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_one_layer_shows_each_size_in_its_scene
    program = game { background :board, tiles: :little, map: Array.new(16) { "#" * 16 } }

    SNES::CheckedRun.new.run(program, frames: 24)
    pass
  end

  # A sprite behind a background on the title, and a bar on the stage: they never share a screen.
  def test_a_sprite_behind_a_background_and_a_bar_on_different_screens
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:big, "#" => :white, "." => :blue) { BIG }
      image(:small, "#" => :red, "." => :green) { SMALL }
      tiles :large, "#" => :big
      tiles :little, "#" => :small
      layers :behind, :ground
      state = var :state, 0
      step = 0
      scene(:title) do
        layer(:behind) { sprite :small, at: [8, 8] }
        layer(:ground) { background :logo, tiles: :large, map: Array.new(8) { "#" * 8 } }
      end
      scene(:stage) do
        layer(:ground) { background :arena, tiles: :large, map: Array.new(8) { "#" * 8 } }
        status_bar :bar, tiles: :little, map: Array.new(4) { "#" * 32 }, top: 192
      end
      game_loop do
        step += 1
        state = 1 if step == 8
        case_var(:state) do
          when_val 0, :title
          when_val 1, :stage
        end
      end
    end
    b.finalize_program

    SNES::CheckedRun.new.run(b.program, frames: 16)
    pass
  end

  def test_a_stage_of_big_cells_under_a_bar_of_small_tiles
    program = game do
      background :arena, tiles: :large, map: Array.new(8) { "#" * 8 }
      status_bar :bar, tiles: :little, map: Array.new(4) { "#" * 32 }, top: 192
    end

    SNES::CheckedRun.new.run(program, frames: 24)
    pass
  end
end
