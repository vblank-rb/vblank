# frozen_string_literal: true

require "test_helper"
require "stringio"
require "made_up_original_layouts"
require "pack_background_tests"

# A SCENE WHOSE BACKGROUND COMES FROM THE DATA PACK ARRIVES AS FAST AS THE SAME PICTURE DRAWN BY HAND.
# A Super Nintendo original's screen is a map of 32 by 32 cells of 16x16, and the console's own game
# shows it as a layer of 16x16 tiles: a map of 2 KB, sent in the blank as the scene comes in. Built
# as 8x8 tiles the same screen is a map of 64 by 64, four times the bytes, and sending it holds the
# game for frames; a note the tune strikes in those frames is struck when the pass ends.
class TestSNESPackSceneArrival < Minitest::Test
  include PackBackgroundGames

  SNES = VBlank::IR::Backends::SNES

  # The pass the map scene takes over, and how many 16x16 cells of the map differ.
  CHANGE_PASS = 30
  DIFFERENT_CELLS = 64
  ACROSS = 32
  # A note every this many frames, a tick a frame (150 beats a minute at 24 ticks a beat).
  NOTE_FRAMES = 3
  MAP_AT = 0x100
  BIG_TILES_AT = 0x1000

  # The first of the four tiles of cell +cell+: t, t + 1, t + 16 and t + 17 in video memory.
  def self.first_tile(cell) = ((cell % 8) * 2) + ((cell / 8) * 32)

  TILE_COUNT = first_tile(DIFFERENT_CELLS - 1) + 18
  # Each tile's places, none alike, and every place drawn.
  TILE_PLACES = Array.new(TILE_COUNT) do |tile|
    Array.new(64) { |at| 1 + (((at * 7) + (tile * 13) + (at * tile)) % 15) }
  end
  CELLS = Array.new(ACROSS * ACROSS) { |at| (at * 37) % DIFFERENT_CELLS }

  def test_a_scene_from_the_pack_arrives_in_no_more_frames_than_the_same_picture_drawn_by_hand
    Dir.mktmpdir do |folder|
      pack = arrival_frames(scene_game(:pack, folder))
      by_hand = arrival_frames(scene_game(:by_hand, folder))

      assert_equal 1, by_hand, "the picture drawn by hand"
      assert_operator pack, :<=, by_hand
    end
  end

  def test_a_note_is_struck_on_its_frame_as_a_scene_from_the_pack_arrives
    Dir.mktmpdir do |folder|
      rom = scene_game(:pack, folder).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
      gaps = strike_gaps(rom)

      assert_equal [NOTE_FRAMES], gaps.uniq, "frames between strikes around the change: #{gaps.inspect}"
    end
  end

  def test_a_scene_from_the_pack_arriving_agrees_with_the_interpreter
    Dir.mktmpdir do |folder|
      SNES::CheckedRun.new.run(scene_game(:pack, folder).program(console: :snes), frames: CHANGE_PASS + 4)
    end
    pass
  end

  private def arrival_frames(game) = SNES::HeadlessRun.new.run(game.program(console: :snes), frames: CHANGE_PASS + 4)
                                                         .frames_took(CHANGE_PASS + 1)

  # The frames between each note the chip is told and the next, over the frames from ten passes
  # before the change to ten after.
  private def strike_gaps(rom)
    places = rom.built
    VBlank::Diagnostics::Emulator.load_snes!
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.sfc") do |core|
      core.run_frame while core.wram_read32(places.waits_counted_at) < CHANGE_PASS - 10
      pitches = []
      until core.wram_read32(places.waits_counted_at) >= CHANGE_PASS + 10
        core.run_frame
        pitches << voice_pitches(core)
      end
      struck = (1...pitches.length).select { |frame| pitches[frame] != pitches[frame - 1] }
      struck.each_cons(2).map { |before, after| after - before }
    end
  end

  # Each voice's pitch, two bytes at 0x02 of each voice's sixteen registers.
  private def voice_pitches(core)
    registers = core.dsp_registers
    Array.new(8) { |voice| registers.byteslice((voice * 0x10) + 2, 2) }
  end

  # A made-up Super Nintendo original: one bank of colours, the tiles and the map of cells.
  private def arrival_original(folder)
    tiles = TILE_PLACES.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
    copy = "\0".b * (BIG_TILES_AT + tiles.bytesize)
    copy[COLORS_AT, 32] = BANKS.first.pack("v*")
    copy[MAP_AT, CELLS.length * 2] = CELLS.map { |cell| SNES_CELL.(TestSNESPackSceneArrival.first_tile(cell)) }.pack("v*")
    copy[BIG_TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A title scene and then, from CHANGE_PASS, a map scene of the original's screen, a tune striking a
  # note every NOTE_FRAMES frames across the change. +how+ is :pack, the screen read from the data
  # pack, or :by_hand, the same cells drawn as pictures of 16x16 the game declares.
  private def scene_game(how, folder)
    from = arrival_original(folder)
    notes = Array.new(80) { |at| VBlank::Audio::Score::Note.new(at: at * NOTE_FRAMES, key: at.even? ? :C4 : :E4, length: NOTE_FRAMES) }
    tune = VBlank::Audio::Score.new(parts: [VBlank::Audio::Score::Part.new(notes: notes)], tempo: 150, ticks_per_beat: 24, length: 80 * NOTE_FRAMES)
    cells = CELLS
    VBlank.game("ARRIVAL", consoles: %i[snes]) do
      screen :tiled
      enable_sound
      music = songs :music, [tune]
      if how == :pack
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: BIG_TILES_AT, count: TILE_COUNT, colors: 16
          slots.numbers :map, at: MAP_AT, count: cells.length, width: :half, signed: false
          slots.colors :palette, at: COLORS_AT, count: 16
        end
      else
        colors :palette_0, BANKS.first
        pictures = cells.uniq.to_h do |cell|
          first = TestSNESPackSceneArrival.first_tile(cell)
          quarters = [first, first + 1, first + 16, first + 17].map { |tile| TILE_PLACES[tile].each_slice(8).to_a }
          places = Array.new(256) { |at| quarters[((at / 128) * 2) + ((at % 16) / 8)][(at / 16) % 8][at % 8] }
          image :"cell_#{cell}", width: 16, height: 16, places: places, colors: :palette_0
          [:"cell_#{cell}", :"cell_#{cell}"]
        end
        tiles :island_tiles, pictures
      end
      state = var :state, 0
      pass = var :pass, 0
      music.play 0
      scene(:title) {}
      scene(:map) do
        if how == :pack
          background :island, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS, cell: 16
        else
          background :island, tiles: :island_tiles, map: cells.each_slice(ACROSS).map { |row| row.map { |cell| :"cell_#{cell}" } }
        end
      end
      game_loop do
        pass += 1
        state = 1 if pass == CHANGE_PASS
        case_var(:state) do
          when_val 0, :title
          when_val 1, :map
        end
      end
    end
  end
end
