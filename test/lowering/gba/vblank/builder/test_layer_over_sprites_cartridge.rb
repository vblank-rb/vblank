# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_layer_over_sprites_on_the_advance"

# A see-through background over sprites on the Advance's cartridge: the picture read back in the
# emulator, and what the cartridge tells the display to mix. What every run that plays games as
# the Advance is held to is in test/console/gba/vblank/builder/test_layer_over_sprites_on_the_advance.rb.
#
# THE DISPLAY MIXES A LAYER WITH THE ONE DIRECTLY BEHIND IT AT EACH PIXEL, and only where that one
# is among the layers its blend control names as the far side. All the sprites are one layer to
# it. So where a sprite is behind a see-through background and the sprites are not named, the
# background is drawn there at full strength: a solid patch the shape of the sprite.
class TestLayerOverSpritesCartridge < Minitest::Test
  include LayerOverSpritesGames

  BLEND_CONTROL = VBlank::Console::Hardware::REG_BLDCNT
  SPRITES_ON_THE_FAR_SIDE = VBlank::Console::Hardware::BLD_OBJ << VBlank::Console::Hardware::BLD_SECOND_SHIFT

  # A sprite shows the pass before, and the first frames are the console setting up.
  CONSOLE_FRAMES = 8

  private def cartridge(program, name, frames: CONSOLE_FRAMES)
    assert_emulator_loads_rom(assemble_rom(program, name: name), frames: frames)
  end

  # The room with sprites behind the cloud in one +way+ alone.
  private def assert_cartridge_mixes_over(way, name)
    console = cartridge(clouded_room([way]), name)

    assert_equal SPRITES_ON_THE_FAR_SIDE, console.mem16(BLEND_CONTROL) & SPRITES_ON_THE_FAR_SIDE,
                 "blend control does not name the sprites on the far side"
    assert_equal half_white_over(SPRITE_COLORS.fetch(way)), console.pixel_gba(*under_cloud(way)), "under the cloud"
    assert_equal SPRITE_COLORS.fetch(way), console.pixel_gba(*on_bare_floor(way)), "beside the cloud"
    assert_equal YELLOW, console.pixel_gba(*under_cloud(:front)), "the sprite in front, over the cloud"
  end

  def test_the_cartridge_mixes_the_cloud_over_a_sprite_declared_behind_it
    assert_cartridge_mixes_over(:plain, "OVRPLN")
  end

  def test_the_cartridge_mixes_the_cloud_over_a_pool_declared_behind_it
    assert_cartridge_mixes_over(:pool, "OVRPOL")
  end

  def test_the_cartridge_mixes_the_cloud_over_a_sprite_put_behind_it_as_the_game_runs
    assert_cartridge_mixes_over(:moved, "OVRMOV")
  end

  def test_the_cartridge_mixes_the_cloud_over_a_pool_put_behind_it_as_the_game_runs
    assert_cartridge_mixes_over(:moved_pool, "OVRMPL")
  end

  def test_the_cartridge_draws_sprites_behind_and_in_front_of_the_cloud_each_their_own_way
    console = cartridge(clouded_room(EVERY_WAY_BEHIND), "OVRALL")

    EVERY_WAY_BEHIND.each do |way|
      assert_equal half_white_over(SPRITE_COLORS.fetch(way)), console.pixel_gba(*under_cloud(way)), "#{way}, under the cloud"
    end
    assert_equal YELLOW, console.pixel_gba(*under_cloud(:front)), "the sprite in front, over the cloud"
    assert_equal YELLOW, console.pixel_gba(*on_bare_floor(:front)), "the sprite in front, over the floor"
    assert_equal half_white_over(RED), console.pixel_gba(UNDER_CLOUD_X, 150), "the floor under the cloud"
  end

  def test_a_scenes_cartridge_names_the_sprites_while_its_room_is_up
    room = clouded_room(EVERY_WAY_BEHIND, scenes: true)

    assert_equal 0, cartridge(room, "OVRTTL", frames: 3).mem16(BLEND_CONTROL), "the title mixes nothing"
    console = cartridge(room, "OVRSCN", frames: SWITCH_AT + CONSOLE_FRAMES)
    assert_equal SPRITES_ON_THE_FAR_SIDE, console.mem16(BLEND_CONTROL) & SPRITES_ON_THE_FAR_SIDE
    EVERY_WAY_BEHIND.each do |way|
      assert_equal half_white_over(SPRITE_COLORS.fetch(way)), console.pixel_gba(*under_cloud(way)), "#{way}, under the cloud"
    end
  end

  # A game with no sprite behind its see-through layer is told nothing new: the sprites are left
  # off the far side, as they were.
  def test_a_room_with_no_sprites_behind_the_cloud_leaves_the_sprites_off_the_far_side
    console = cartridge(clouded_room_with_no_sprites_behind, "OVRNON")

    assert_equal 0, console.mem16(BLEND_CONTROL) & SPRITES_ON_THE_FAR_SIDE
    assert_equal YELLOW, console.pixel_gba(*under_cloud(:front))
  end
end
