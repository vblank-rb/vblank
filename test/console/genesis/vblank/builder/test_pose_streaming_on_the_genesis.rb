# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "many_tiles"
require "made_up_original_layouts"

# A sprite whose poses do not all fit in video memory beside the scene's other pictures. A Genesis
# holds 1471 tiles at once, and the console's own games keep room for the one frame a big character
# shows, copying that frame's tiles in from the cartridge in the blank as he changes to it. Every
# pass is held to the interpreter's picture, so a pose drawn from the wrong tiles, or from tiles
# copied a frame late, fails at the pass it shows.
class TestPoseStreamingOnTheGenesis < Minitest::Test
  # The tiles of the background, all different.
  GROUND_TILES = 400

  # The sprite's poses, a hundred tiles each (ManyTiles#declare_sprite_pictures): with the
  # background, more than video memory holds.
  POSES = 16

  # A screen of GROUND_TILES different tiles behind sprites facing POSES big poses: +walkers+ of
  # them, each stepping to its next pose every +rate+ frames, the first from its first pose.
  private def walkers_over_a_big_ground(walkers: 1, rate: 1)
    poses = POSES
    count = GROUND_TILES
    b = Builder.new
    b.instance_eval do
      screen :tiled
      map = ManyTiles.declare(self, :ground, count, :red)
      background :ground, tiles: :ground, map: map
      frames = ManyTiles.declare_sprite_pictures(self, :boss, poses, :green, from: count)
      Array.new(walkers) { |i| sprite :"walker_#{i}", at: [8 + (i * 90), 16 + (i * 20)], frames: frames, rate: rate + i }
      tick = var :tick, 0
      game_loop { tick += 1 }
    end
    b.finalize_program
    b.program
  end

  def test_a_sprite_whose_poses_do_not_fit_shows_each_pose_as_it_changes_to_it
    game_player.run(walkers_over_a_big_ground, frames: POSES * 2 + 3)
    pass
  end

  # A pose held for some frames, and the pose shown again after the others.
  def test_a_pose_held_and_shown_again_shows_its_own_tiles
    game_player.run(walkers_over_a_big_ground(rate: 3), frames: (POSES * 3) + 9)
    pass
  end

  # Two sprites facing the same poses, changing at different paces: each keeps room of its own.
  def test_two_sprites_facing_the_same_poses_each_show_their_own
    game_player.run(walkers_over_a_big_ground(walkers: 2, rate: 2), frames: (POSES * 2) + 5)
    pass
  end

  # --- poses read from a data pack's frames ---

  # A frame as a Genesis game keeps one: a word that counts its pieces, then the console's own
  # sprite entry for each.
  FRAME = VBlank::Original::FrameLayout.new(
    piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    y_at: 0, x_at: 6, position_bytes: 2, tile_at: 4, tile_bytes: 2, tile_bits: 11,
    flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12, bank_bit: 13, bank_bits: 2,
    size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  )

  # Each frame is PIECES_ACROSS by PIECES_DOWN pieces of four tiles by four, each piece naming tiles
  # of its own: 96 tiles a frame, and FRAMES frames more than video memory holds.
  PIECES_ACROSS = 3
  PIECES_DOWN = 2
  PIECE_TILES = 16
  FRAME_TILES = PIECES_ACROSS * PIECES_DOWN * PIECE_TILES
  FRAMES = 16
  # Tile 0 draws nothing; tile n draws its number's bits and ManyTiles's corner in place 1 over place 2.
  TILES = Array.new(1 + (FRAMES * FRAME_TILES)) do |n|
    Array.new(64) { |at| n.zero? ? 0 : (ManyTiles.drawn?(n, at % 8, at / 8) ? 1 : 2) }
  end.freeze
  FRAME_BYTES = Array.new(FRAMES) do |frame|
    pieces = Array.new(PIECES_ACROSS * PIECES_DOWN) do |piece|
      tile = 1 + (frame * FRAME_TILES) + (piece * PIECE_TILES)
      [(piece / PIECES_ACROSS) * 32, 0x0F, 0, tile | 0x8000, (piece % PIECES_ACROSS) * 32].pack("s>CCns>")
    end
    [pieces.length].pack("n") + pieces.join
  end.freeze
  BOX = [PIECES_ACROSS * 32, PIECES_DOWN * 32].freeze
  COLORS_AT = 0x40
  FRAMES_AT = 0x100
  TILES_AT = 0x1000

  # A made-up original holding those tiles, frames and a list of colours, written into +folder+.
  private def original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    colors = MadeUpOriginalLayouts::LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    frames = FRAME_BYTES.join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[FRAMES_AT, frames.bytesize] = frames
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A sprite facing every frame of the original in +folder+ in turn, each pose read from the data
  # pack's frames, over a background of GROUND_TILES different tiles.
  private def pack_walker_over_a_big_ground(folder)
    from = original(folder)
    count = GROUND_TILES
    VBlank.game("POSE ROOM", consoles: %i[genesis]) do
      screen :tiled
      map = ManyTiles.declare(self, :ground, count, :red)
      background :ground, tiles: :ground, map: map
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.sum(&:bytesize), width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      names = Array.new(FRAMES) do |k|
        name = :"frame_#{k}"
        image name, tiles: pack[:video], frame: pack[:frames].frame(FRAME_BYTES.first(k).sum(&:bytesize), layout: FRAME),
                    origin: [0, 0], colors: pack[:palette], size: BOX
        name
      end
      sprite :boss, at: [100, 40], frames: names, rate: 2
      tick = var :tick, 0
      game_loop { tick += 1 }
    end.program(console: :genesis)
  end

  def test_poses_read_from_a_data_packs_frames_show_each_frame_as_it_changes_to_it
    Dir.mktmpdir do |folder|
      game_player.run(pack_walker_over_a_big_ground(folder), frames: (FRAMES * 2) + 3)
    end
    pass
  end
end
