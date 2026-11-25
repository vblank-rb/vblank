# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_pack_background_areas"

# A background from the data pack walking between areas, on the Advance's cartridge, read in the
# emulator. What it shows on every run is in test/all/vblank/builder/test_pack_background_areas.rb.
class TestPackBackgroundAreasCartridge < Minitest::Test
  include PackBackgroundAreaGames
  include Differential

  private def one_slot_walk(folder)
    program, = areas_game_and_file(areas_original(folder), one_tile_slot: true) do |world|
      PackBackgroundAreaGames.emit_walk_beside_sprite(self, world)
    end
    program
  end

  # Bringing an area's tiles in switches the layers off and holds the sprites still for a frame
  # (BackgroundDrawing#emit_bring_set_in). Areas over one slot of tiles have nothing to bring in, so
  # the frame of the walk shows the sprite where the interpreter puts it.
  def test_areas_over_one_tile_slot_show_the_sprite_on_time_as_the_game_walks
    Dir.mktmpdir do |folder|
      assert_backends_agree(one_slot_walk(folder), frames: (WALKS_ON - 1)..(WALKS_ON + 3))
    end
  end

  # The walk is a copy of the map alone: the cartridge holds no routine that brings tiles in.
  def test_areas_over_one_tile_slot_hold_no_routine_bringing_tiles_in
    Dir.mktmpdir do |folder|
      routines = assemble_rom(one_slot_walk(folder)).built.routines.keys.map { |name| VBlank::Messages::MadeNames.words_for_made_name(name) }

      refute_includes routines, "bringing background :world another set of tiles"
    end
  end

  # Maps of two widths over one slot of tiles: the cartridge streams each map at its own size and
  # shows what the interpreter shows on every frame of the walk.
  def test_areas_of_two_widths_over_one_tile_slot_show_each_map_as_the_interpreter_does
    Dir.mktmpdir do |folder|
      program, = areas_game_and_file(areas_original(folder), one_tile_slot: true, across: ACROSS_BY_AREA) do |world|
        PackBackgroundAreaGames.emit_walk_beside_sprite(self, world)
      end

      assert_backends_agree(program, frames: (WALKS_ON - 1)..(WALKS_ON + 3))
    end
  end

  # Areas of slots of their own still bring their tiles in, so the routine is there to miss.
  def test_areas_of_their_own_slots_bring_their_tiles_in
    Dir.mktmpdir do |folder|
      program, = areas_game_and_file(areas_original(folder)) { |world| PackBackgroundAreaGames.emit_walk_beside_sprite(self, world) }
      routines = assemble_rom(program).built.routines.keys.map { |name| VBlank::Messages::MadeNames.words_for_made_name(name) }

      assert_includes routines, "bringing background :world another set of tiles"
    end
  end
end
