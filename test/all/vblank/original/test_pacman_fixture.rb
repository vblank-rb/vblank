# frozen_string_literal: true

require "test_helper"
require "digest"
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s

# THE PAC-MAN PORT'S MADE-UP ORIGINAL (test/fixtures/pacman_port/): pacman.gba, built once from
# examples/pacman.rb and checked in with its SHA-1, and the facts of where its data is. A real
# cartridge never changes, so these hold the checked-in file to its facts and do not rebuild it.
class TestPacmanFixture < Minitest::Test
  Packer = VBlank::IR::Backends::GBA::BiosCompress

  private def rom = File.binread(PacmanFixture::ROM_PATH)

  def test_the_checked_in_cartridge_is_the_one_the_facts_name
    facts = PacmanFixture.facts.fetch("rom")

    assert_equal facts.fetch("sha1"), Digest::SHA1.hexdigest(rom)
    assert_equal facts.fetch("size"), rom.bytesize
  end

  def test_the_cartridge_holds_assets_packed_with_both_schemes
    codecs = PacmanFixture.facts.fetch("assets").map { |asset| asset.fetch("codec") }

    assert_includes codecs, "lz77"
    assert_includes codecs, "rle"
  end

  # The answer key is apart from the port's unpacking and from the decoder: packing what a decoder
  # unpacked, with the scheme the facts name, gives back the bytes in the cartridge.
  def test_every_packed_asset_unpacks_to_bytes_that_pack_back_to_it
    PacmanFixture.facts.fetch("assets").each do |asset|
      next if asset.fetch("codec") == "none"

      block = rom.byteslice(asset.fetch("at"), asset.fetch("size"))
      unpacked = PacmanFixture.unpack_block(block)
      scheme = asset.fetch("codec").to_sym
      repacked = Packer.with_bios_header(Packer.public_send(scheme, unpacked), { lz77: Packer::TYPE_LZ77, rle: Packer::TYPE_RLE }.fetch(scheme),
                                         unpacked.bytesize)

      assert_equal asset.fetch("unpacked_size"), unpacked.bytesize, asset.fetch("name")
      assert_equal block, repacked, "#{asset.fetch('name')} packs back to the cartridge's bytes"
    end
  end

  def test_a_cartridge_that_packs_nothing_cannot_be_the_original
    nothing = [VBlank::Cartridge::BuildRecord::DataAsset.new(name: :wall, at: 0, size: 8, codec: :none, unpacked_size: 8)]
    refused = assert_raises(ArgumentError) { PacmanFixture.refuse_unpacked!(nothing) }

    assert_match "packs nothing", refused.message
  end

  def test_a_cartridge_that_packs_with_one_scheme_only_cannot_be_the_original
    only_lz77 = [VBlank::Cartridge::BuildRecord::DataAsset.new(name: :tiles, at: 0, size: 8, codec: :lz77, unpacked_size: 32)]
    refused = assert_raises(ArgumentError) { PacmanFixture.refuse_unpacked!(only_lz77) }

    assert_match "rle is not used", refused.message
  end
end
