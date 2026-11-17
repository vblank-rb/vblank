# frozen_string_literal: true

require "digest/sha2"
require "json"
require_relative "near_names"

module VBlank
  module Original
    # An asset the manifest does not hold. The message names the assets nearest it.
    class UnknownAsset < KeyError; end

    # A MANIFEST THAT CANNOT BE TRUE: two assets on the same bytes, or a copy that does not hold an
    # asset where the manifest says. The message names each asset.
    class ManifestRefused < StandardError; end

    # WHERE EACH ASSET LIES IN THE ORIGINAL: its offset in the copy, its length and the SHA-256 of its
    # bytes (never the bytes, which a port may not keep). A port's harvest makes it from the extents
    # Decompilation proved, saves it, and its tests hold the player's copy to it:
    #
    #   decomp.harvest(ORIGINAL.copy) do |built|
    #     extents = incbins.map { |path, at| built.extent(path, at: at) }
    #     Manifest.from_extents(extents, ORIGINAL.copy).write("data/manifest.json")
    #   end
    #   Manifest.read("data/manifest.json").refuse_different_copy!(ORIGINAL.copy)   # in a test
    #
    # No two assets may claim the same bytes: one of them is in the wrong place, and that is refused
    # when the manifest is made or read. The file is JSON, an asset to a line, in order of offset.
    #
    # Required on its own (`require "vblank/original/manifest"`), by a port's harvest and its tests: a
    # game that reads no original never loads it.
    class Manifest
      include Enumerable

      # One asset: its name, where it starts in the copy, how many bytes, and their SHA-256.
      Asset = Data.define(:name, :offset, :length, :sha256) do
        # The bytes it covers, as a range of offsets.
        def range = offset...(offset + length)
      end

      # The first key of a saved file, which says what it is and in which version of the format.
      FORMAT_VERSION = 1
      # How many problems a refusal lists before it stops.
      LISTED_PROBLEMS = 20

      # A manifest of +extents+ (Decompilation::Extent, or anything with a source, offset and length),
      # each asset hashed from +copy+ (an accepted Copy, or its path). Each asset is named by its
      # source, or by what the block gives back for its extent.
      def self.from_extents(extents, copy)
        bytes = copy_bytes(copy)
        new(extents.map do |extent|
          name = block_given? ? yield(extent) : extent.source
          Asset.new(name: name, offset: extent.offset, length: extent.length,
                    sha256: Digest::SHA256.hexdigest(bytes.byteslice(extent.offset, extent.length).to_s))
        end)
      end

      # The manifest saved at +path+.
      def self.read(path)
        raise ArgumentError, "There is no saved manifest at #{path}. Run the port's harvest to write it." unless File.file?(path)

        saved = JSON.parse(File.read(path))
        unless saved.is_a?(Hash) && saved["manifest"] == FORMAT_VERSION && saved["list"].is_a?(Array)
          raise ArgumentError, "#{path} is not a saved manifest. Run the port's harvest again to write it."
        end

        new(saved["list"].map do |row|
          Asset.new(name: row.fetch("name"), offset: Integer(row.fetch("offset")), length: row.fetch("length"), sha256: row.fetch("sha256"))
        end)
      end

      def self.copy_bytes(copy) = copy.respond_to?(:read_bytes) ? copy.read_bytes : File.binread(copy)

      def initialize(assets)
        @assets = assets.sort_by { [it.offset, it.name] }
        @by_name = @assets.to_h { [it.name, it] }
        refuse_twice_named!
        refuse_overlaps!
      end

      def each(&) = @assets.each(&)

      # The asset named +name+, or UnknownAsset naming those nearest it.
      def fetch(name)
        @by_name.fetch(name) do
          near = NearNames.among(@by_name.keys, name)
          hint = near.empty? ? "" : " Near names are: #{near.join(', ')}."
          raise UnknownAsset, "There is no asset #{name} in the manifest.#{hint}"
        end
      end

      def include?(name) = @by_name.key?(name)

      # Refuses +copy+ (an accepted Copy, or its path) unless it holds every asset's bytes where the
      # manifest says: a copy of another release, or damaged, or a manifest out of date.
      def refuse_different_copy!(copy)
        bytes = self.class.copy_bytes(copy)
        different = @assets.reject do |asset|
          held = bytes.byteslice(asset.offset, asset.length)
          held && held.bytesize == asset.length && Digest::SHA256.hexdigest(held) == asset.sha256
        end
        return if different.empty?

        listed = different.first(LISTED_PROBLEMS).map { "  #{it.name} (#{it.length} bytes at #{hex(it.offset)})" }
        raise ManifestRefused, "The copy does not hold #{different.size} of the assets where the manifest says:\n" \
                               "#{listed.join("\n")}\nThe copy must be the release that the harvest read. " \
                               "If it is, run the harvest again."
      end

      # The manifest as the saved file's text: an asset to a line, in order of offset.
      def saved_text
        rows = map { JSON.generate({ "name" => it.name, "offset" => hex(it.offset), "length" => it.length, "sha256" => it.sha256 }) }
        "{\"manifest\":#{FORMAT_VERSION}, \"list\": [\n#{rows.join(",\n")}\n]}\n"
      end

      def write(path) = File.write(path, saved_text)

      # True when the file at +path+ is not this manifest as #write writes it.
      def stale?(path) = !File.file?(path) || File.read(path) != saved_text

      private

      def refuse_twice_named!
        twice = @assets.map(&:name).tally.select { |_, count| count > 1 }.keys
        raise ManifestRefused, "These names are on more than one asset: #{twice.join(', ')}. Give each asset its own name." unless twice.empty?
      end

      def refuse_overlaps!
        clashes = overlapping_pairs
        return if clashes.empty?

        listed = clashes.first(LISTED_PROBLEMS).map do |first, second|
          "  #{first.name} (#{first.length} bytes at #{hex(first.offset)}) runs into #{second.name} (at #{hex(second.offset)})"
        end
        raise ManifestRefused, "#{clashes.size} assets run into the asset after them:\n#{listed.join("\n")}\n" \
                               "Two assets cannot hold the same bytes. Correct the place or the length the harvest gives."
      end

      # Each asset that starts before an earlier one ends, paired with the earlier one reaching
      # furthest: the one before it is not enough, since a long asset can cover several after it.
      def overlapping_pairs
        furthest = nil
        @assets.filter_map do |asset|
          pair = [furthest, asset] if furthest && furthest.range.end > asset.offset
          furthest = asset if furthest.nil? || asset.range.end > furthest.range.end
          pair
        end
      end

      def hex(number) = format("0x%x", number)
    end
  end
end
