# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s

# THE CARTRIDGE BUILD'S RECORD OF ITS DATA (BuildRecord#data_assets): where each piece the build
# laid down after the code starts in the finished file, how it is packed and how big it is unpacked.
# The Pac-Man port reads its facts from it (test/fixtures/pacman_port/).
class TestBuildRecordDataAssets < Minitest::Test
  SCHEME_NUMBERS = { lz77: 1, rle: 3 }.freeze

  def test_a_packed_asset_starts_with_its_scheme_and_unpacked_size_where_the_record_says
    built = PacmanFixture.build
    packed = built.assets.reject { |asset| asset.codec == :none }

    refute_empty packed
    packed.each do |asset|
      header = built.bytes.byteslice(asset.at, 4)

      assert_equal SCHEME_NUMBERS.fetch(asset.codec), header.getbyte(0) >> 4, "#{asset.name} starts with its scheme"
      assert_equal asset.unpacked_size, header.getbyte(1) | (header.getbyte(2) << 8) | (header.getbyte(3) << 16), asset.name
    end
  end
end
