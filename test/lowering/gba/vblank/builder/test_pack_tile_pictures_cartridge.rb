# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_pack_tile_pictures"

# A TILE OF A BACKGROUND FROM THE DATA PACK TAKING TURNS THROUGH PICTURES, ON THE ADVANCE'S
# CARTRIDGE, read in the emulator and held to the interpreter frame for frame. What such a tile
# shows on every run is in test/all/vblank/builder/test_pack_tile_pictures.rb.
class TestPackTilePicturesCartridge < Minitest::Test
  include PackTilePictureGames
  include Differential

  def test_the_cartridge_shows_the_tile_taking_turns_as_the_interpreter_does
    Dir.mktmpdir do |folder|
      program, = belt_game_and_file(folder) { |belt, tick| belt.show((tick / 2) % 3) }

      assert_backends_agree(program, frames: 1..9, name: "PACKBELT")
    end
  end

  def test_the_cartridge_shows_the_tile_of_a_background_in_a_scene_as_the_interpreter_does
    Dir.mktmpdir do |folder|
      program, = belt_game_and_file(folder, in_scene: true) { |belt, tick| belt.show((tick / 2) % 3) }

      assert_backends_agree(program, frames: 1..9, name: "PACKBELTS")
    end
  end
end
