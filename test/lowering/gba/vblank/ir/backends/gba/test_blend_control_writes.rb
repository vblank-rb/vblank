# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "differential"

# What the blend unit is told, write by write, in a game whose light takes turns with a scene that
# mixes a layer. The console draws from whatever the register holds at that moment, and an
# interrupt can stop a pass for dozens of rows. So a pass that writes a value it means to replace
# can leave that value in force for part of a picture, and no reading taken once a frame would show
# it. Each pass has to say its last word and nothing before it.
class TestBlendControlWrites < Minitest::Test
  include Differential

  BLEND_CONTROL = VBlank::Console::Hardware::REG_BLDCNT
  DARKEN_EVERYTHING = 0xFF
  NOTHING = 0
  MIX_WATER_OVER_GROUND = 0x2142 # the second background over the first and the backdrop
  TURN = 6 # the pass the game changes scene on

  # A title that sees through water, a dim room faded under a lid, and a scene with a light, which
  # runs +lit+ on each pass. The game starts in scene +from+ and changes to +to+ on pass 6.
  private def three_scenes(from:, to:, lit: nil)
    numbers = { title: 0, dim: 1, playing: 2 }
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      mode = var :mode, numbers.fetch(from)
      turn = var :turn, 0
      spotlight at: [120, 80], radius: 40, dark: 100
      scene(:title) { layer(:water, transparency: 50) { background :pond, tiles: :set, map: ["r" * 32] * 32 } }
      scene(:dim) do
        layer(:water) { background :lid, tiles: :set, map: ["r" * 32] * 32 }
        fade :black, 50, under: :water
      end
      scene(:playing) { instance_exec(&lit) if lit }
      game_loop do
        turn += 1
        mode = numbers.fetch(to) if turn == TURN
        call({ 0 => :title, 1 => :dim, 2 => :playing }, number: :mode)
      end
    end
    b.finalize_program
    b.program
  end

  # The values written to blend control, oldest first.
  private def blend_control_values(program, name, frames: 30)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "blend.gba")
      assemble_rom(program, name: name).write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        probe.step(frames)
        probe.display_writes.select { |write| write.kind == :register && write.address == BLEND_CONTROL }.map(&:value)
      ensure
        probe.close
      end
    end
  end

  # What +values+ held in turn, a value written again counted once.
  private def distinct_runs(values) = values.chunk_while { |a, b| a == b }.map(&:first)

  def test_the_light_comes_on_through_nothing_and_stays_on
    assert_equal [MIX_WATER_OVER_GROUND, NOTHING, DARKEN_EVERYTHING],
                 distinct_runs(blend_control_values(three_scenes(from: :title, to: :playing), "LIT")).last(3)
  end

  def test_a_scene_the_light_is_off_in_goes_straight_to_its_own_mixing
    assert_equal [DARKEN_EVERYTHING, MIX_WATER_OVER_GROUND],
                 distinct_runs(blend_control_values(three_scenes(from: :playing, to: :title), "LEAVE")).last(2)
  end

  # A tint takes the place of a fade the display was doing, and hands the blend back if one was. The
  # light's darkening looks like such a fade, and is not one.
  def test_a_tint_in_a_lit_scene_leaves_the_light_alone
    game = three_scenes(from: :title, to: :playing, lit: -> { tint :red, 30 })

    assert_equal DARKEN_EVERYTHING, distinct_runs(blend_control_values(game, "TINT")).last
    assert_backends_agree(game, frames: [3, 8, 12], name: "TINTED")
  end

  # A fade on every pass of a game with a light and no scenes, which walks the colours and puts
  # away any fade the display was doing.
  def test_a_fade_on_every_pass_leaves_the_light_on
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      spotlight at: [120, 80], radius: 40, dark: 100
      game_loop do
        fade :black, 50
        wait_vblank
      end
    end
    b.finalize_program

    assert_backends_agree(b.program, frames: [3, 8], name: "FADED")
  end
end
