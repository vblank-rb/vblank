# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/original/manifest"

# A port's harvest records where each asset lies in the original (Original::Manifest), from the
# extents Original::Decompilation proved, and its tests hold the player's copy to that record. The
# original here is made up: a header, a ship's pixels and a tune, one after another.
class TestManifest < Minitest::Test
  Extent = VBlank::Original::Decompilation::Extent
  Manifest = VBlank::Original::Manifest

  HEADER = "HEADER--"
  SHIP = "ship pixels"
  TUNE = "do re mi"
  COPY = HEADER + SHIP + TUNE

  EXTENTS = [Extent.new(source: "gfx/ship.bin", offset: 8, length: SHIP.bytesize, sha1: Digest::SHA1.hexdigest(SHIP)),
             Extent.new(source: "audio/tune.bin", offset: 19, length: TUNE.bytesize, sha1: Digest::SHA1.hexdigest(TUNE))].freeze

  private def copy(folder, bytes = COPY) = File.join(folder, "rocket.bin").tap { File.binwrite(it, bytes) }

  def test_each_extent_is_an_asset_with_its_place_length_and_sha256
    Dir.mktmpdir do |folder|
      manifest = Manifest.from_extents(EXTENTS, copy(folder))
      ship = manifest.fetch("gfx/ship.bin")

      assert_equal [8, SHIP.bytesize, Digest::SHA256.hexdigest(SHIP)], [ship.offset, ship.length, ship.sha256]
      assert_equal 8...19, ship.range
      assert_equal %w[gfx/ship.bin audio/tune.bin], manifest.map(&:name)
    end
  end

  def test_a_block_names_each_asset
    Dir.mktmpdir do |folder|
      manifest = Manifest.from_extents(EXTENTS, copy(folder)) { File.basename(it.source, ".bin").capitalize }

      assert_equal 19, manifest.fetch("Tune").offset
    end
  end

  def test_two_assets_on_the_same_bytes_are_refused_naming_both
    clash = Manifest::Asset.new(name: "gfx/ship_tail.bin", offset: 15, length: 6, sha256: "0" * 64)
    error = assert_raises(VBlank::Original::ManifestRefused) do
      Dir.mktmpdir { |folder| Manifest.new(Manifest.from_extents(EXTENTS, copy(folder)).to_a + [clash]) }
    end

    assert_match "gfx/ship_tail.bin", error.message
    assert_match "audio/tune.bin", error.message
  end

  # A long asset can cover several after it, the second of them clear of the first.
  def test_an_asset_covering_two_after_it_is_refused_with_each
    whole = Manifest::Asset.new(name: "whole.bin", offset: 0, length: COPY.bytesize, sha256: "0" * 64)
    error = assert_raises(VBlank::Original::ManifestRefused) do
      Dir.mktmpdir { |folder| Manifest.new(Manifest.from_extents(EXTENTS, copy(folder)).to_a + [whole]) }
    end

    assert_match "2 assets", error.message
  end

  def test_the_copy_it_was_made_from_passes_and_a_changed_one_is_refused_naming_the_asset
    Dir.mktmpdir do |folder|
      manifest = Manifest.from_extents(EXTENTS, copy(folder))
      manifest.refuse_different_copy!(copy(folder))

      changed = assert_raises(VBlank::Original::ManifestRefused) { manifest.refuse_different_copy!(copy(folder, "#{HEADER}ship pixelz#{TUNE}")) }
      short = assert_raises(VBlank::Original::ManifestRefused) { manifest.refuse_different_copy!(copy(folder, HEADER + SHIP)) }

      assert_match "gfx/ship.bin", changed.message
      refute_match "audio/tune.bin", changed.message
      assert_match "audio/tune.bin", short.message
    end
  end

  def test_an_unknown_asset_is_refused_naming_what_is_near
    Dir.mktmpdir do |folder|
      error = assert_raises(VBlank::Original::UnknownAsset) { Manifest.from_extents(EXTENTS, copy(folder)).fetch("gfx/shp.bin") }

      assert_match "gfx/ship.bin", error.message
    end
  end

  def test_a_saved_manifest_reads_back_the_same_one_asset_to_a_line
    Dir.mktmpdir do |folder|
      manifest = Manifest.from_extents(EXTENTS, copy(folder))
      path = File.join(folder, "manifest.json")
      manifest.write(path)

      assert_equal manifest.to_a, Manifest.read(path).to_a
      assert_equal 1, File.read(path).lines.count { it.include?("gfx/ship.bin") }
      refute manifest.stale?(path)
      assert Manifest.new(manifest.first(1)).stale?(path)
    end
  end

  def test_a_file_that_is_not_a_saved_manifest_is_refused
    Dir.mktmpdir do |folder|
      path = File.join(folder, "manifest.json")
      File.write(path, "[]\n")

      assert_match "manifest", assert_raises(ArgumentError) { Manifest.read(path) }.message
    end
  end
end
