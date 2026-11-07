# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"

# A GAME HANDED ITS DATA PACK AS IT STARTS, played as C and checked against the interpreter on
# every frame (PackAtStartTests in test/pack_at_start_tests.rb, which says why these are not in
# test/all/). The C runtime reads the file it is handed and fills the tables, the tiles and the
# pictures that come from it before the game's first statement.
class TestNativePackAtStart < Minitest::Test
  include PackAtStartTests
  include PackAtStartLayoutTests

  # C writes every array as its numbers.
  def test_the_game_as_c_holds_none_of_the_originals_bytes
    assert_written_without_the_originals_bytes(ways: %i[numbers]) { |program| VBlank::IR::Backends::Native.new.lower(program) }
  end

  def test_a_game_of_each_consoles_layout_as_c_holds_none_of_the_originals_bytes
    assert_layouts_written_without_the_originals_bytes { |program| VBlank::IR::Backends::Native.new.lower(program) }
  end

  # A game that reads no file is written as it was before there was one: its tiles' pixels kept where
  # they cannot be written, and nothing read at start.
  def test_a_game_with_no_data_pack_reads_no_start_file
    Dir.mktmpdir do |folder|
      written = VBlank::IR::Backends::Native.new.lower(game_program(held_directly))

      assert_match(/^const uint16_t rg_game_tile_pixels\[/, written)
      refute_match(/rg_start_file/, written)
      assert_match(/rg_start_file_open/, VBlank::IR::Backends::Native.new.lower(pack_at_start_game(folder)))
    end
  end
end
