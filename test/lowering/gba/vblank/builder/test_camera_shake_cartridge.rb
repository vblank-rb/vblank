# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_camera_shake"

# The screen shake on the Advance's cartridge, read back in the emulator. What the camera and
# the shake do on every run is in test/all/vblank/builder/test_camera_shake.rb.
class TestCameraShakeCartridge < Minitest::Test
  include CameraShakeGames

  # The shake really moves the picture on the hardware, and really puts it back.
  # Two ROMs of the same game stopped at different frames: one mid-shake, one after.
  def test_the_shake_moves_the_picture_on_the_console_and_restores_it
    mid = ROM.assemble(GBA.new.lower(shaking_game(frames: 4, intensity: 6, length: 6)),
                       title: "SHAKE", code: "BSHK", maker: "01")
    done = ROM.assemble(GBA.new.lower(shaking_game(frames: 20, intensity: 6, length: 3)),
                        title: "SHAKE", code: "BSHK", maker: "01")

    during = assert_emulator_loads_rom(mid, frames: 6)
    after = assert_emulator_loads_rom(done, frames: 24)

    # The block was drawn across x 100..139. After the shake it is exactly there.
    assert after.red?(120, 80), "the block should be back where it was drawn, " \
                                "got 0x#{format('%04X', after.pixel_gba(120, 80))}"

    # Two points just outside the block, one past each edge. Settled, both show
    # background. Under a 6px shake the picture has slid one way or the other, so one
    # of them is covered by the block — whichever way this frame happens to lean.
    assert during.red?(97, 80) || during.red?(142, 80),
           "mid-shake the picture should have slid over one of the two edge points"
    refute after.red?(97, 80), "settled, the block covers neither"
    refute after.red?(142, 80)
  end

  # On a tiled screen the shake moves the background's scroll registers and the sprite's place
  # together. A 2-pixel shake leans one way or the other: the green square drawn with its corner
  # at (100, 60) has it at (98, 58) or (102, 62), and the red stripe at the left edge, 4 pixels
  # wide, has its first or its third pixel turned blue to match.
  def test_the_shake_moves_a_tiled_screen_on_the_console_and_restores_it
    mid = ROM.assemble(GBA.new.lower(tiled_shaking_game(frames: 10, length: 20)),
                       title: "SHAKE", code: "BSHK", maker: "01")
    done = ROM.assemble(GBA.new.lower(tiled_shaking_game(frames: 14, length: 3)),
                        title: "SHAKE", code: "BSHK", maker: "01")

    during = assert_emulator_loads_rom(mid, frames: 14)
    after = assert_emulator_loads_rom(done, frames: 18)

    corner_at = ->(x, y) { during.green?(x, y) && !during.green?(x - 1, y) && !during.green?(x, y - 1) }
    leaned_left = corner_at.call(98, 58) && during.blue?(2, 30) && during.red?(0, 30)
    leaned_right = corner_at.call(102, 62) && during.blue?(0, 30) && during.red?(2, 30)
    assert leaned_left || leaned_right, "mid-shake the background and the sprite moved the same way"

    assert after.green?(100, 60) && !after.green?(99, 60) && !after.green?(100, 59),
           "settled, the sprite is back where it was placed"
    assert after.red?(0, 30) && after.red?(3, 30) && after.blue?(4, 30), "and the background is back too"
  end
end
