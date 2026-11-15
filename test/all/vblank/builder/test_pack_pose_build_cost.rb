# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "all/vblank/builder/test_pack_poses_sharing_tiles"

# MANY POSES OVER ONE BIG SHEET OF TILES, as an original keeps every tile of a sprite type in one
# slot of thousands. Each pose reads four tiles from a tile of its own on, so declaring them all
# reads what they draw and nothing more: what a build costs follows the tiles its poses draw,
# however big the sheet. The made-up original is the Genesis one of
# test_pack_poses_sharing_tiles.rb, its frames a word that counts the pieces, then a piece of 2 by 2
# tiles at the pose's first tile.
class TestPackPoseBuildCost < Minitest::Test
  SHARED = SharedSlotTilesGame

  # Big enough that reading it whole for each pose was the build's whole cost.
  SHEET_TILES = 2048
  POSE_COUNT = 32
  # Where each pose's tiles start in the sheet, spread over the whole of it.
  POSE_STEP = SHEET_TILES / POSE_COUNT
  PIECE = SHARED::Piece.new(x: 0, y: 0, columns: 2, rows: 2, tile: 0)
  FRAME_BYTES = ([1].pack("n") + PIECE.bytes).freeze
  # Tile n of the sheet draws as the sharing test's tile 1 + n % 10, so neighbours differ.
  SHEET_TILE = ->(n) { SHARED::TILE.(1 + (n % 10)) }
  # The two poses the screen shows, and where.
  SHOWN = { 3 => [16, 40], 29 => [64, 40] }.freeze

  COLORS_AT = 0x40
  FRAMES_AT = 0x100
  TILES_AT = 0x200

  def test_declaring_poses_reads_only_the_tiles_they_draw
    Dir.mktmpdir do |folder|
      b = pose_sheet_builder(folder)

      assert_equal POSE_COUNT * PIECE.columns * PIECE.rows, b.pack_tiles_read
    end
  end

  def test_each_pose_shows_the_tiles_from_its_own_start
    Dir.mktmpdir do |folder|
      b = pose_sheet_builder(folder)
      screen = game_player.run(b.program, frames: 4).screen

      SHOWN.each do |pose, (left, top)|
        expected = (0...16).flat_map do |y|
          (0...16).map do |x|
            tile = (pose * POSE_STEP) + ((x / 8) * PIECE.rows) + (y / 8)
            SHARED::BANK.fetch(SHEET_TILE.(tile)[((y % 8) * 8) + (x % 8)])
          end
        end
        shown = (0...16).flat_map { |y| (0...16).map { |x| screen.pixel(left + x, top + y) } }
        assert_equal expected, shown, "pose #{pose}"
      end
    end
  end

  private

  def pose_sheet_original(folder)
    tiles = (0...SHEET_TILES).map { |n| MadeUpOriginalLayouts::HIGH_HALF_FIRST.(SHEET_TILE.(n)) }.join
    colors = MadeUpOriginalLayouts::LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[FRAMES_AT, FRAME_BYTES.bytesize] = FRAME_BYTES
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A pose for each start in the sheet, all over the one frame, and a sprite for each pose SHOWN.
  def pose_sheet_builder(folder)
    from = pose_sheet_original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sheet, at: TILES_AT, count: SHEET_TILES, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.bytesize, width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      POSE_COUNT.times do |pose|
        image :"pose_#{pose}", tiles: pack[:sheet].tile(pose * POSE_STEP), frame: pack[:frames].frame(0, layout: SHARED::FRAME),
                               origin: [0, 0], colors: pack[:palette]
      end
      SHOWN.each { |pose, at| sprite :"pose_#{pose}", at: at }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b
  end
end
