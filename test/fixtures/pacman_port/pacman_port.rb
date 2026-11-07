#!/usr/bin/env ruby
# frozen_string_literal: true

# Pac-Man, PORTED: examples/pacman.rb played with none of its data in the program. The room, the
# colours and the pictures of Pac, the pellets and the ghost are read from pacman.gba, the
# cartridge that example builds, which stands in for a retail original (pacman_fixture.rb). The
# port holds the game's code and nothing the cartridge holds.
#
# A port is built two ways, and plays the same either way:
#
# - all-in-one, as `vblank build` or a test builds it: the data pack is made from the copy as the game
#   is built. Set PACMAN_ROM to the path of pacman.gba (or a settings file, pacman_port.yml beside
#   this file, with `rom: PATH`).
# - as a shell, `vblank run test/fixtures/pacman_port/pacman_port.rb --shell`: the program holds
#   none of the data, and on the first run Load ROM takes pacman.gba, unpacks it into a data pack kept
#   on the player's machine, and the next runs never read the cartridge.
#
# THE UNPACKING is game code (`slots.fill_from_copy`). The cartridge keeps most of its data
# packed with the Advance's BIOS schemes, LZ77 and run-length, and the routine undoes both. Where
# each piece is in the file is a fact (pacman_facts.yml, written by tools/make_pacman_fixture.rb
# from the cartridge build's own record); what each piece is, the port's own knowledge below, is
# what a decompilation's labels give a real port.
#
# Every asset the cartridge packs is unpacked into the pack, and the picture of every one is drawn
# from it, the letters and digits of the score included (a picture font of the cartridge's glyph tiles).
#
# THE SOUNDS are the one thing not read from it. The cartridge holds no sound settings as data: the
# Advance's build writes waka and caught as writes to the sound registers in its code, so there is
# nothing in the file to unpack. A real port reads them from a decompilation's sound tables, so the
# port keeps them as define_sound lines. Nothing in the cartridge is a tune.

require "yaml"
require_relative "../../../lib/vblank"

module PacmanPort
  FACTS = Ractor.make_shareable(YAML.safe_load_file(File.join(__dir__, "pacman_facts.yml")))
  ROM_FACTS = FACTS.fetch("rom")
  ASSETS = Ractor.make_shareable(FACTS.fetch("assets").to_h { |asset| [asset.fetch("name"), asset] })

  SPEED = 2
  SIZE  = 16
  DIRS  = %i[right left up down].freeze
  GHOST_START = [24, 24].freeze
  HUD_X   = 8
  HUD_GAP = 6

  # Where the screen's cells are in the cartridge's map: a row of it is 32 cells, of which the screen shows
  # the first 30 of 20 rows. A cell is a tile number in the low ten bits (and a palette bank above).
  MAP_ROW_CELLS = 32
  TILE_NUMBER_BITS = 0x3FF
  # The cartridge's tile numbers of the wall and the floor, and the tileset keys the port gives them.
  CARTRIDGE_WALL = 2
  WALL = 0
  FLOOR = 1

  # The cartridge's palettes, in banks of 16: the room's colours are in bank 1 of the background palette;
  # of the sprite palette, the ghost and the pellet draw from bank 0 (red, white), Pac from bank 1 (yellow); bank 2 is
  # the white he blinks in.
  ROOM_BANK = 1
  GHOST_BANK = 0
  PAC_BANK = 1
  PELLET_BANK = 0
  HUD_BANK = 0
  # The cartridge draws each glyph 6 pixels on from the last, in an 8-pixel tile.
  HUD_GLYPH_ADVANCE = 6
  # Where the cartridge's digits start after SCORE: its five letters 6 apiece, the last 5 pixels across.
  SCORE_LABEL_WIDTH = 29

  # Pac's pictures in the cartridge, each four tiles (16x16): his mouth open to the right, shut, open
  # to the left, up and down.
  PAC_PICTURES = %i[open_right shut open_left open_up open_down].freeze
  PAC_FRAMES = Ractor.make_shareable({ right: %i[open_right shut], left: %i[open_left shut], up: %i[open_up shut],
                                       down: %i[open_down shut] })

  Layout = Data.define(:width, :height) do
    def floor_x = (8..(width - 8 - SIZE))
    def floor_y = (8..(height - 8 - SIZE))
    def start = [(width - SIZE) / 2, (height - SIZE) / 2]
    def pellet_spots = [[(width / 2) - 8, 40], [48, 40], [width - 56, 40], [48, height - 48], [width - 56, height - 48]]
    def columns = width / 8
    def rows = height / 8
  end

  # The copy of the original this port reads: the release it knows, by the SHA-1 and size the facts hold.
  def self.original(env: ENV)
    VBlank::Original::Game.new(
      title: "Pac-Man", setting: "PACMAN_ROM", settings_file: File.join(__dir__, "pacman_port.yml"), env: env,
      releases: { "VBlank example" => { "sha1" => ROM_FACTS.fetch("sha1"), "size" => ROM_FACTS.fetch("size") } },
      not_set_help: "Set it to test/fixtures/pacman_port/pacman.gba, the cartridge examples/pacman.rb builds."
    )
  end

# The slots of the score's letters and digits, by the asset's build name. The cartridge drew them
# as sprites from bank HUD_BANK of its sprite palette; digit_tiles holds a blank, then 0 to 9.
# Every asset the cartridge packs is unpacked, so the routine is tried on each of them.
UNDRAWN_SLOTS = Ractor.make_shareable(
    { score_s_tile: "__obj_tiles___hud8", score_c_tile: "__obj_tiles___hud9", score_o_tile: "__obj_tiles___hud10",
      score_r_tile: "__obj_tiles___hud11", score_e_tile: "__obj_tiles___hud12", digit_tiles: "__obj_tiles___hud13" }
  )

  # Each slot of the pack and the asset of the cartridge it is unpacked from, by the asset's build name.
  SLOT_ASSETS = Ractor.make_shareable(
    { room_palette: "__bg_shared_pal", room_tiles: "__bg_shared_char", room_map: "__bg_map_room",
      sprite_palette: "__obj_palette", pac_tiles: "__obj_tiles___obj1", pellet_tiles: "__obj_tiles___obj2",
      ghost_tiles: "__obj_tiles___obj7", **UNDRAWN_SLOTS }
  )

  # Pac-Man as a port of +from+; +version+ names the build in its data pack.
  def self.game(from = original, version: "1")
    VBlank.game("PACMAN", consoles: %i[gba]) do
      screen :tiled
      here = Layout.new(width: screen_width, height: screen_height)

      layers :room, :pellets, :actors, :ui

      enable_sound
      define_sound :waka,   frequency: 660, duty: :half, decay: :fast
      define_sound :caught, frequency: 90,  duty: :half, decay: :slow, volume: 12
      seed 1

      # The pack: each slot is a piece of the cartridge unpacked. The sizes are the unpacked sizes.
      pack = data_pack(from: from, version: version) do |slots|
        slots.colors  :room_palette, count: 32
        slots.tiles   :room_tiles, count: 4
        slots.numbers :room_map, count: 1024, width: :half, signed: false
        slots.colors  :sprite_palette, count: 48
        slots.tiles   :pac_tiles, count: 20
        slots.tiles   :pellet_tiles, count: 1
        slots.tiles   :ghost_tiles, count: 4
        UNDRAWN_SLOTS.each do |name, asset|
          slots.tiles name, count: ASSETS.fetch(asset).fetch("unpacked_size") / (VBlank::Original::Slot::TILE_PIXELS / 2)
        end
        slots.fill_from_copy do |copy, into|
          SLOT_ASSETS.each do |name, asset|
            fact = ASSETS.fetch(asset)
            copy.public_send(:"unpack_#{fact.fetch('codec')}", at: fact.fetch("at"), into: into[name])
          end
        end
      end

      # --- the room: two tiles, and the cartridge's map of them ---
      room_colors = pack[:room_palette].bank(ROOM_BANK)
      image :wall, width: 8, height: 8, colors: room_colors, places: pack[:room_tiles].tile(CARTRIDGE_WALL)
      image :floor, width: 8, height: 8, colors: room_colors, places: pack[:room_tiles].tile(CARTRIDGE_WALL + 1)
      tiles :dungeon, WALL => :wall, FLOOR => :floor
      maze = table :maze, pack[:room_map]
      room = layer(:room) do
        background :room, tiles: :dungeon, map: Array.new(here.rows) { Array.new(here.columns, FLOOR) }
      end
      repeat(here.rows) do |row|
        repeat(here.columns) do |column|
          room.set_tile column, row, (maze[(row * MAP_ROW_CELLS) + column] & TILE_NUMBER_BITS) - CARTRIDGE_WALL
        end
      end

      # --- Pac-Man: a chomp per direction, from the cartridge's five pictures ---
      pac_colors = pack[:sprite_palette].bank(PAC_BANK)
      PAC_PICTURES.each_with_index do |picture, at|
        image :"pac_#{picture}", width: SIZE, height: SIZE, colors: pac_colors,
                                 places: pack[:pac_tiles].tiles(at * 4, across: 2, down: 2)
      end
      colors :flash, [:transparent, *[:white] * 15]
      pac = layer(:actors) do
        sprite :pac, at: here.start, rate: 6, facing: PAC_FRAMES.transform_values { |frames| frames.map { |frame| :"pac_#{frame}" } }
      end
      stunned = 0

      # --- the pellets ---
      image :pellet, width: 8, height: 8, colors: pack[:sprite_palette].bank(PELLET_BANK), places: pack[:pellet_tiles].tile(0)
      pellets = layer(:pellets) { here.pellet_spots.map { |px, py| sprite :pellet, at: [px, py] } }
      eaten = 0

      # --- the ghost ---
      image :ghost, width: SIZE, height: SIZE, colors: pack[:sprite_palette].bank(GHOST_BANK),
                    places: pack[:ghost_tiles].tiles(0, across: 2, down: 2)
      ghost = layer(:actors) { sprite :ghost, at: GHOST_START }
      caught = 0

# --- the score: the letters and digits are the cartridge's own glyph tiles ---
hud_colors = pack[:sprite_palette].bank(HUD_BANK)
score_letters = { "S" => :score_s_tile, "C" => :score_c_tile, "O" => :score_o_tile,
                  "R" => :score_r_tile, "E" => :score_e_tile }
score_letters.each do |letter, slot|
  image :"hud_#{letter}", width: 8, height: 8, colors: hud_colors, places: pack[slot].tile(0)
end
image :hud_blank, width: 8, height: 8, colors: hud_colors, places: pack[:digit_tiles].tile(0)
("0".."9").each do |digit|
  image :"hud_#{digit}", width: 8, height: 8, colors: hud_colors, places: pack[:digit_tiles].tile(digit.to_i + 1)
end
font :score_font, spacing: HUD_GLYPH_ADVANCE - 8,
                  pictures: (score_letters.keys + ("0".."9").to_a).to_h { |c| [c, :"hud_#{c}"] }.merge(" " => :hud_blank)
score_label_width = ("SCORE".length * HUD_GLYPH_ADVANCE) - (HUD_GLYPH_ADVANCE - 8)

layer :ui do
  draw_text "SCORE", HUD_X, 4, font: :score_font
  draw_number :eaten, HUD_X + SCORE_LABEL_WIDTH + HUD_GAP, 4, digits: 3, font: :score_font
end

      game_loop do
        pac.move :left,  by: SPEED if held(:left)
        pac.move :right, by: SPEED if held(:right)
        pac.move :up,    by: SPEED if held(:up)
        pac.move :down,  by: SPEED if held(:down)
        pac.x.clamp! here.floor_x.min, here.floor_x.max
        pac.y.clamp! here.floor_y.min, here.floor_y.max

        pellets.each do |pellet|
          if pac.overlaps?(pellet)
            eaten += 1
            beep :waka
            pellet.move_to rand(here.floor_x), rand(here.floor_y)
          end
        end

        ghost.move :right if ghost.x < pac.x
        ghost.move :left if ghost.x > pac.x
        ghost.move :down if ghost.y < pac.y
        ghost.move :up if ghost.y > pac.y

        if ghost.overlaps?(pac)
          beep :caught
          caught += 1
          pac.move_to(*here.start)
          ghost.move_to(*GHOST_START)
          stunned = 48
        end

        if stunned > 0
          stunned -= 1
          pac.draw_with [:flash], showing: (stunned >> 2) & 1
        else
          pac.draw_with :own
        end
      end
    end
  end

  GAME = game
end
