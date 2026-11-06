# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"

# A GAME HANDED ITS DATA PACK AS IT STARTS, played as C and checked against the interpreter on
# every frame (PackAtStartTests in test/pack_at_start_tests.rb, which says why these are not in
# test/all/). The C runtime reads the file it is handed and fills the tables and the tiles that come
# from it before the game's first statement.
class TestNativePackAtStart < Minitest::Test
  include PackAtStartTests

  # C writes every array as its numbers.
  def test_the_game_as_c_holds_none_of_the_originals_bytes
    assert_written_without_the_originals_bytes(ways: %i[numbers]) { |program| VBlank::IR::Backends::Native.new.lower(program) }
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

  # The art for a blit or a sprite is worked out from the picture's pixels as the game is built,
  # and a picture read from the pack has none then: refused naming it, not drawn wrong. (The
  # JavaScript and Ruby lowerings are this one's statements, so they refuse it alike.)
  def test_a_picture_read_from_the_pack_cannot_be_blitted_yet
    Dir.mktmpdir do |folder|
      b = VBlank::Builder.new(options: PACK_AT_START)
      from = original(folder)
      b.instance_eval do
        screen :bitmap
        pack = data_pack(from: from, version: "1") do |slots|
          slots.colors :palette, at: PALETTE_AT, count: 16
          slots.tiles :walls, at: TILES_AT, count: 2
        end
        image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
        game_loop { blit :wall, 10, 10 }
      end
      b.finalize_program
      refused = assert_raises(VBlank::IR::Backends::Native::LoweringError) { VBlank::IR::Backends::Native.new.lower(b.program) }

      assert_match ":wall", refused.message
      assert_match "background's tile", refused.message
    end
  end
end
