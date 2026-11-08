# frozen_string_literal: true

require "test_helper"
require "digest"
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_port").to_s

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

  # THE PORT'S ROUTINE UNPACKS EVERY ASSET THE CARTRIDGE PACKS to the bytes the cartridge build
  # packed. The answer key is the build's own packer: each slot of the pack the port's all-in-one
  # build makes, packed again with the scheme the facts name, is the block in the cartridge.
  def test_the_ports_routine_unpacks_every_packed_asset_to_the_bytes_the_build_packed
    port = PacmanPort.game(PacmanPort.original(env: { "PACMAN_ROM" => PacmanFixture::ROM_PATH }))
    pack = VBlank::Original::Pack.from_bytes(port.data_pack_file)
    packed = PacmanFixture.facts.fetch("assets").reject { |asset| asset.fetch("codec") == "none" }

    assert_equal packed.map { |asset| asset.fetch("name") }.sort, PacmanPort::SLOT_ASSETS.values.sort, "a slot for every packed asset"
    PacmanPort::SLOT_ASSETS.each do |slot, name|
      scheme = PacmanFixture.asset(name).fetch("codec").to_sym
      unpacked = pack.bytes_of(slot)
      repacked = Packer.with_bios_header((scheme == :lz77 ? Packer.lz77(unpacked) : Packer.rle(unpacked)), { lz77: Packer::TYPE_LZ77, rle: Packer::TYPE_RLE }.fetch(scheme),
                                         unpacked.bytesize)

      assert_equal PacmanFixture.asset(name).fetch("unpacked_size"), unpacked.bytesize, name
      assert_equal PacmanFixture.block_of(rom, name), repacked, "#{name}, unpacked by the port, packs back to the cartridge's bytes"
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
