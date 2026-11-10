# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"
require "pack_sound_tests"

# A GAME HANDED ITS DATA PACK AS IT STARTS, played as Ruby and checked against the interpreter on
# every frame (PackAtStartTests in test/pack_at_start_tests.rb, which says why these are not in
# test/all/). The Ruby runtime fills the tables and the tiles from the file it is handed, as the C
# runtime does.
class TestRubyPackAtStart < Minitest::Test
  include PackAtStartTests
  include PackAtStartLayoutTests
  include PackSoundTests

  # Ruby writes a small array as its numbers and a big one as base64.
  def test_the_game_as_a_ruby_script_holds_none_of_the_originals_bytes
    assert_written_without_the_originals_bytes(ways: %i[numbers base64]) do |program|
      VBlank::IR::Backends::Ruby.new.script(program, title: "Made Up")
    end
  end

  def test_a_game_of_each_consoles_layout_as_a_ruby_script_holds_none_of_the_originals_bytes
    assert_layouts_written_without_the_originals_bytes { |program| VBlank::IR::Backends::Ruby.new.script(program, title: "Made Up") }
  end

  # The Ruby file asked to leave the pack out (`vblank build --format ruby --pack-at-start`) reads no
  # copy, and plays the game reading its pack as it starts.
  def test_a_ruby_file_built_with_its_pack_left_out_reads_no_copy
    Dir.mktmpdir do |folder|
      game = game_reading_pack_with_no_copy(folder)
      path = VBlank::IR::Backends::Ruby.new.build_script(game, File.join(folder, "made_up.rb"), console: :gba, err: nil,
                                                                                               pack_at_start: true)

      assert_match(/rg_start_file_open/, File.read(path))
    end
  end
end
