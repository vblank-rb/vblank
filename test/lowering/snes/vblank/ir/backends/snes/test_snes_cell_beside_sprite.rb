# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A CELL AND A SPRITE CHANGED IN ONE PASS SHOW TOGETHER. Both wait for the same blank, however much
# of the frame the pass takes, read here from the console's own picture.
class TestSNESCellBesideSprite < Minitest::Test
  RED = 0x7C00
  GREEN = 0x03E0
  CHANGED_ON = 20

  private def game(work)
    changed_on = CHANGED_ON
    VBlank.build("CELLS", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:wall, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:dot, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :wall, "." => :floor
      room = background :room, tiles: :set, map: Array.new(28) { "#" * 32 }
      hero = sprite :dot, at: [40, 40]
      passes = var :passes, 0
      busy = var :busy, 0
      game_loop do
        passes += 1
        repeat(work) { busy += 1 }
        if passes == changed_on
          20.times { |cell| room.set_tile cell + 2, 2, "." }
          hero.x = 100
        end
      end
    end
  end

  # The frame the cell and the frame the sprite each reach the picture.
  private def frames_shown(work)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cells.sfc")
      game(work).write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path, save_dir: dir)
      cell = sprite = nil
      40.times do |frame|
        core.run_frame
        colors = core.colors
        cell ||= frame if colors[(20 * core.width) + 20] == RED
        sprite ||= frame if colors[(44 * core.width) + 104] == GREEN
      end
      core.destroy
      [cell, sprite]
    end
  end

  def test_a_cell_and_a_sprite_changed_in_one_pass_reach_the_picture_together
    [0, 200, 300].each do |work|
      cell, sprite = frames_shown(work)

      assert cell, "the cell changes with #{work} steps of work"
      assert_equal sprite, cell, "with #{work} steps of work"
    end
  end
end
