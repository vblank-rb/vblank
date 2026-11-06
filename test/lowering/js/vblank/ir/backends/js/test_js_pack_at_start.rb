# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"

# A GAME HANDED ITS DATA PACK AS IT STARTS, played as JavaScript and checked against the
# interpreter on every frame (PackAtStartTests in test/pack_at_start_tests.rb, which says why these
# are not in test/all/). The JavaScript runtime fills the tables and the tiles from the file it is
# handed, as the C runtime does.
class TestJSPackAtStart < Minitest::Test
  include PackAtStartTests

  # JavaScript writes a small array as its numbers and a big one as base64.
  def test_the_game_as_javascript_holds_none_of_the_originals_bytes
    assert_written_without_the_originals_bytes(ways: %i[numbers base64]) { |program| VBlank::IR::Backends::JS.new.lower(program) }
  end

  # The web build asked to leave the pack out (`vblank build --format web --pack-at-start`) reads no
  # copy, and the page reads its pack as the game starts.
  def test_a_page_built_with_its_pack_left_out_reads_no_copy
    Dir.mktmpdir do |folder|
      game = game_reading_pack_with_no_copy(folder)
      path = VBlank::IR::Backends::JS.new.build_module(game, File.join(folder, "made_up.mjs"), console: :gba, err: nil,
                                                                                             pack_at_start: true)

      assert_match(/rg_start_file_open/, File.read(path))
    end
  end
end
