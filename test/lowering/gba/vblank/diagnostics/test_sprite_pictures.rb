# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "sprite_picture_tests"

class TestSpritePictures < Minitest::Test
  include SpritePictureTests

  private def console = :gba

  # The console's table is read straight: what it holds on a frame is what the pass before placed.
  def test_a_row_of_the_table_names_its_picture
    reader = VBlank::Diagnostics::Verifier.new(picture_game, frames: 5)

    assert_equal [:walk1], reader.sprites(:hero).map(&:picture), "picked in the third pass, shown after the fourth"
  end

  def test_a_cartridge_file_has_no_names
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gba")
      picture_game.write(path)
      reader = VBlank::Diagnostics::Verifier.new(VBlank::Diagnostics::CartridgeFile.new(path), frames: 2)

      assert_match(/not built here/, assert_raises(ArgumentError) { reader.watch_sprites }.message)
    end
  end
end
