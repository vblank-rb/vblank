# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "made_up_original"

# A MADE-UP ORIGINAL THAT IS A FOLDER OF FILES, the way a computer game's is (Wolfenstein 3D's
# VSWAP.WL6, MAPHEAD.WL6 and the rest), and a port reading it, for the copy, copy reader and shell
# tests. The folder is test/fixtures/folder_original/:
#
# - INDEX.MU1, a header: "MUIX", how many pieces there are as two bytes, and where each piece
#   starts in DATA.MU1 as four bytes, low byte first. The routine reads these places as it runs, as
#   Wolfenstein's reads GAMEMAPS through MAPHEAD.
# - data.mu1, the pieces with filler between: MadeUpOriginal's colours, two tiles and heights. Its
#   name on disk is lower case and the release spells it DATA.MU1, as a copy made through another
#   system often is.
# - CONFIG.MU1 and README.TXT, files that are no part of the release: a settings file the original
#   rewrites as it is played, and a note. Neither is read, so changing them changes nothing.
module FolderOriginal
  include MadeUpOriginal

  FOLDER = VBlank.root.join("test/fixtures/folder_original").to_s

  # Where each piece starts in DATA.MU1, as INDEX.MU1 holds it: the colours, the tiles, the heights.
  PIECE_STARTS = [16, 53, 120].freeze

  # The one release, as a port lists it: each file it reads, with its SHA-1 and size.
  RELEASES = {
    "MU1" => { "files" => { "INDEX.MU1" => { "sha1" => "32dfaae2482389106cf7261e591eb75a2a79f93f", "size" => 18 },
                            "DATA.MU1" => { "sha1" => "14687c66a75899e0d39ad00b230306d0d287ad3b", "size" => 154 } } }
  }.freeze

  VBlank::Testing::InRactors.share_constants(self)

  # The made-up original from a computer, whose copy is +folder+ (the fixture unless given; nil for a
  # machine with no copy).
  private def folder_original(folder = FOLDER)
    VBlank::Original::Game.new(title: "Folder Game", setting: "FOLDER_GAME_DATA", env: folder ? { "FOLDER_GAME_DATA" => folder } : {},
                               settings_file: File.join(Dir.tmpdir, "folder_game.yml"), key: "data", releases: RELEASES,
                               platform: :pc)
  end

  # The fixture copied into +into+, so a test can change, take away or add a file.
  private def fixture_copy_in(into)
    File.join(into, "copy").tap { |copy| FileUtils.cp_r(FOLDER, copy) }
  end

  # The port's slots: three pieces, each found through INDEX.MU1 as the routine runs. Public, as the
  # port's block calls it back.
  def folder_slots(slots)
    slots.colors :palette, count: 16, layout: :gba
    slots.tiles :walls, count: 2, layout: :gba, colors: 16
    slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
    slots.fill_from_copy do |copy, pack, release|
      index = copy.file("INDEX.#{release}")
      data = copy.file("DATA.#{release}")
      %i[palette walls heights].each_with_index do |slot, piece|
        data.copy_bytes at: index.word(6 + (4 * piece)), count: pack[slot].byte_size, into: pack[slot]
      end
    end
  end

  # The port: the two tiles as a background, and a marker placed by the heights, as ShellTests#port.
  private def folder_port(from, version: "1")
    test = self
    VBlank.game("FOLDER GAME", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: version) { |slots| test.folder_slots(slots) }
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :wall_b, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        draw_rect_at heights[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 15
      end
    end
  end
end
