# frozen_string_literal: true

require "digest"
require "yaml"
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "vblank"

# THE MADE-UP ORIGINAL OF THE PAC-MAN PORT: pacman.gba, the cartridge VBlank builds from
# examples/pacman.rb, checked in once with its SHA-1, and the facts of where each piece of data is in it.
#
# It stands in for a retail cartridge, in the console's own formats (16-colour tiles, 15-bit colours,
# the BIOS's packing), and is ours, so it can live in the repository. It is not rebuilt by a test:
# any change to the Advance lowering changes its bytes and its hash, and a real cartridge never
# changes. `ruby tools/make_pacman_fixture.rb` writes it again, on purpose, along with the facts.
#
# THE FACTS come from the cartridge build's own record of where it laid each piece of data
# (Cartridge::BuildRecord#data_assets), the way a real port takes them from a decompilation's
# labels, and are written as an Original::FactsFile.
module PacmanFixture
  FOLDER = File.expand_path(__dir__).freeze
  ROM_PATH = File.join(FOLDER, "pacman.gba").freeze
  FACTS_PATH = File.join(FOLDER, "pacman_facts.yml").freeze

  # The schemes a retail cartridge packs its data with, and which the port's unpacking must undo.
  SCHEMES = %i[lz77 rle].freeze
  Ractor.make_shareable(SCHEMES)

  # A cartridge and where it laid its data.
  Built = Data.define(:bytes, :assets)

  # THE FACTS FILE'S COMMENTS, written by hand; the tool writes the values under them.
  FACTS_TEXT = <<~YAML
    # Where Pac-Man's data is in pacman.gba, the cartridge built from examples/pacman.rb. Written by
    # tools/make_pacman_fixture.rb from the cartridge build's own record, never by hand.

    # The cartridge these facts are about.
    rom:
      # The SHA-1 of pacman.gba, 40 hex digits: the release a port accepts.
      sha1: 0
      # The size of pacman.gba in bytes.
      size: 0

    # Every piece of data the cartridge holds after its code: its build name, the byte it starts at, the
    # bytes it takes there, how it is packed (lz77, rle or none), and its bytes once unpacked.
    assets: []
  YAML

  module_function

  # The example built as a cartridge, and the build's record of its data. Stops, saying why, for a
  # cartridge that packs nothing or packs with one scheme only (#refuse_unpacked!).
  def build
    load VBlank.root.join("examples/pacman.rb").to_s unless defined?(::Pacman::GAME)
    rom = ::Pacman::GAME.build_rom(out: nil, err: nil, profile: false, console: :gba)
    assets = rom.built.data_assets
    refuse_unpacked!(assets)
    Built.new(bytes: rom.buffer.dup.b, assets: assets)
  end

  # The facts as a hash, written as the facts file's values.
  def facts_of(built)
    { "rom" => { "sha1" => Digest::SHA1.hexdigest(built.bytes), "size" => built.bytes.bytesize },
      "assets" => built.assets.map do |asset|
        { "name" => asset.name.to_s, "at" => asset.at, "size" => asset.size, "codec" => asset.codec.to_s,
          "unpacked_size" => asset.unpacked_size }
      end }
  end

  # Writes the cartridge and its facts, where the port and the tests read them.
  def write(built = build)
    File.binwrite(ROM_PATH, built.bytes)
    File.write(FACTS_PATH, VBlank::Original::FactsFile.merge(FACTS_TEXT, facts_of(built)))
  end

  # Why a cartridge cannot be the original: packing is what the port's unpacking exists to undo, and a
  # cartridge with none of one scheme leaves that scheme untried.
  def refuse_unpacked!(assets)
    used = assets.map(&:codec).uniq - [:none]
    missing = SCHEMES - used
    return if missing.empty?

    raise ArgumentError, "The cartridge packs #{used.empty? ? 'nothing' : used.map(&:to_s).join(' and ')}, and the port's " \
                         "unpacking must undo #{SCHEMES.join(' and ')}. #{missing.join(' and ')} is not used. A change to " \
                         "the Advance lowering stopped it packing, or this example no longer has an asset that needs it."
  end

  # The bytes the asset +name+ takes in +rom+, packed as the cartridge keeps it.
  def block_of(rom, name)
    fact = asset(name)
    rom.byteslice(fact.fetch("at"), fact.fetch("size"))
  end

  # The facts, as the port reads them.
  def facts = YAML.safe_load_file(FACTS_PATH)

  # The fact of the asset built as +name+: its place, size, packing and unpacked size.
  def asset(name, facts: self.facts)
    facts.fetch("assets").find { |found| found.fetch("name") == name.to_s } or
      raise KeyError, "The facts hold no asset called #{name}. They hold #{facts.fetch('assets').map { |found| found['name'] }.join(', ')}."
  end
end
