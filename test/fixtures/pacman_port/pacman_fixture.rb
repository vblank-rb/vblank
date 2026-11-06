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

  # The pack the all-in-one build makes from the cartridge: every slot as the cartridge's assets
  # unpack, in the order the port names its slots.
  def expected_pack
    rom = File.binread(ROM_PATH)
    assets = { room_palette: "__bg_shared_pal", room_tiles: "__bg_shared_char", room_map: "__bg_map_room",
               sprite_palette: "__obj_palette", pac_tiles: "__obj_tiles___obj1", pellet_tiles: "__obj_tiles___obj2",
               ghost_tiles: "__obj_tiles___obj7" }
    VBlank::Original::Pack.holding(assets.transform_values { |name| unpacked_asset(rom, name) },
                                   sha1: facts.fetch("rom").fetch("sha1"), build_version: "1").to_bytes
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

  # A block packed with the BIOS's LZ77 or run-length scheme, unpacked: the answer key for the port's
  # unpacking, written apart from it. The first four bytes are the scheme (top half of the first)
  # and the size unpacked (the next three, low byte first).
  def unpack_block(block)
    scheme = block.getbyte(0) >> 4
    size = block.getbyte(1) | (block.getbyte(2) << 8) | (block.getbyte(3) << 16)
    out = []
    at = 4
    until out.size >= size
      if scheme == 3
        flag = block.getbyte(at)
        at += 1
        if flag.anybits?(0x80)
          out.concat([block.getbyte(at)] * ((flag & 0x7F) + 3))
          at += 1
        else
          out.concat(block.bytes[at, (flag & 0x7F) + 1])
          at += (flag & 0x7F) + 1
        end
      else
        flag = block.getbyte(at)
        at += 1
        8.times do |item|
          break if out.size >= size

          if flag.anybits?(0x80 >> item)
            high = block.getbyte(at)
            distance = (((high & 0xF) << 8) | block.getbyte(at + 1)) + 1
            at += 2
            ((high >> 4) + 3).times { out << out[-distance] }
          else
            out << block.getbyte(at)
            at += 1
          end
        end
      end
    end
    out.first(size).pack("C*")
  end

  # The bytes of the asset +name+ in +rom+, unpacked.
  def unpacked_asset(rom, name)
    fact = asset(name)
    block = rom.byteslice(fact.fetch("at"), fact.fetch("size"))
    fact.fetch("codec") == "none" ? block : unpack_block(block)
  end

  # The facts, as the port reads them.
  def facts = YAML.safe_load_file(FACTS_PATH)

  # The fact of the asset built as +name+: its place, size, packing and unpacked size.
  def asset(name, facts: self.facts)
    facts.fetch("assets").find { |found| found.fetch("name") == name.to_s } or
      raise KeyError, "The facts hold no asset called #{name}. They hold #{facts.fetch('assets').map { |found| found['name'] }.join(', ')}."
  end
end
