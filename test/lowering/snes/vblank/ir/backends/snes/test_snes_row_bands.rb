# frozen_string_literal: true

require "test_helper"

# A BACKGROUND SPLIT INTO BANDS OF ROWS costs a game little, in a scene or out of one: the console
# is told where each band starts, and not every line. This pass nearly fills its frame with no bend
# at all, and it keeps its frame with one.
class TestSNESRowBands < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  STEPS = 320
  ART = (["#.#.#.#."] * 8).join("\n").freeze

  private def game(in_scene:)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    steps = STEPS
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :white, "." => :blue) { ART }
      tiles :set, "#" => :dot
      upper = var :upper, 0
      lower = var :lower, 0
      split = 100
      work = var :work, 0
      put_up = lambda do
        layer = background :logo, tiles: :set, map: "####"
        layer.scroll_each_row { |row| row >= split ? lower - upper : 0 }
      end
      put_up.call unless in_scene
      scene(:title) { put_up.call } if in_scene
      var :state, 0
      game_loop do
        case_var(:state) { when_val 0, :title } if in_scene
        repeat(steps) { work += 1 }
        lower += 1
      end
    end
    b.finalize_program
    b.program
  end

  private def long_passes(program)
    run = SNES::HeadlessRun.new.run(program, frames: 100)
    (40...100).select { |pass| run.frames_took(pass) > 1 }
  end

  def test_a_two_band_scroll_keeps_a_busy_pass_on_its_frame
    assert_empty long_passes(game(in_scene: false))
  end

  def test_a_two_band_scroll_in_a_scene_keeps_a_busy_pass_on_its_frame
    assert_empty long_passes(game(in_scene: true))
  end
end
