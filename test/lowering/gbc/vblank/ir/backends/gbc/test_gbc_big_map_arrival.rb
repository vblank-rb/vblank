# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "digest"
require "made_up_original_layouts"

# A scene whose background map is 64 by 64 cells arrives on its first frame, as the interpreter shows
# it. The Color's grid is 32 by 32 cells, so a bigger map is kept in the cartridge and the cells the
# view is over are put in the grid (Runtime::BigMaps): for a map just put up, the whole view of 21 by
# 19 cells. The console's own games put a screen up in a blank without losing a frame, so the pass the
# scene takes over on takes one frame, and a note the tune strikes then is struck on its frame.
class TestGBCBigMapArrival < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # The pass the map scene takes over, and how many different tiles the map is made of.
  CHANGE_PASS = 30
  DIFFERENT_CELLS = 256
  ACROSS = 64
  # A note every this many frames.
  NOTE_FRAMES = 3
  PALETTE = [0x0000, 0x7FFF, 0x001F, 0x03E0].freeze
  # Where the view is put, a pass each, in pixels: a cell part way in, across the grid's 32nd column
  # and row, at the map's right and bottom edges. A view past the edges, where the map comes round, is
  # held on every run by test/all/vblank/builder/test_big_maps.rb.
  VIEW_SPOTS = [[3, 5], [237, 245], [352, 368], [100, 40], [255, 255], [0, 368], [352, 0], [17, 201], [0, 0]].freeze
  # Where the made-up original keeps its colours, its map and its tiles.
  COLORS_AT = 0x10
  MAP_AT = 0x40
  TILES_AT = 0x4000

  # Each tile's places, none alike, every tile drawing something.
  CELL_PLACES = Array.new(DIFFERENT_CELLS) do |tile|
    Array.new(64) { |at| 1 + ((((tile + 1) >> (at % 10)) + (at * 3) + tile) % 3) }
  end
  CELLS = Array.new(ACROSS * ACROSS) { |at| (at * 37) % DIFFERENT_CELLS }

  VBlank::Testing::InRactors.share_constants(self)

  def test_a_scene_with_a_map_of_64_by_64_cells_arrives_in_one_frame
    run = GBC::HeadlessRun.new.run(scene_game.program(console: :gbc), frames: CHANGE_PASS + 4)

    assert_equal 1, run.frames_took(CHANGE_PASS + 1)
  end

  def test_a_scene_with_a_big_map_from_the_pack_arrives_in_one_frame
    Dir.mktmpdir do |folder|
      run = GBC::HeadlessRun.new.run(scene_game(pack_from: arrival_original(folder)).program(console: :gbc), frames: CHANGE_PASS + 4)

      assert_equal 1, run.frames_took(CHANGE_PASS + 1)
    end
  end

  def test_a_note_is_struck_on_its_frame_as_a_scene_with_a_big_map_arrives
    gaps = strike_gaps(scene_game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false))

    assert_equal [NOTE_FRAMES], gaps.uniq, "frames between strikes around the change: #{gaps.inspect}"
  end

  def test_a_scene_with_a_big_map_arriving_agrees_with_the_interpreter
    GBC::CheckedRun.new.run(scene_game.program(console: :gbc), frames: CHANGE_PASS + 4)
    pass
  end

  # The view jumped about the map, a whole view worked out each time, coming round the grid's rows and
  # columns, as the interpreter shows it.
  def test_a_view_jumping_about_a_big_map_agrees_with_the_interpreter
    GBC::CheckedRun.new.run(jumping_game, frames: VIEW_SPOTS.length + 2)
    pass
  end

  # The frames between each note the player strikes and the next, from ten passes before the change
  # to ten after: a strike is the player moving its part on to the note after (Runtime::Music::NEXT).
  private def strike_gaps(rom)
    runtime = rom.built.runtime
    passes_at = runtime.fetch(GBC::Runtime::Frame::PASSES)
    next_at = runtime.fetch(GBC::Runtime::Music::NEXT)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gbc")
      rom.write(path)
      core = RubyGBAEmulator::Core.new(path, dir, nil)
      # Work memory holds what it held at power-on until the cartridge clears it, a few frames in.
      10.times { core.run_frame }
      core.run_frame while core.bus_read32(passes_at) < CHANGE_PASS - 10
      notes = []
      until core.bus_read32(passes_at) >= CHANGE_PASS + 10
        core.run_frame
        notes << (core.bus_read8(next_at) | (core.bus_read8(next_at + 1) << 8))
      end
      struck = (1...notes.length).select { |frame| notes[frame] != notes[frame - 1] }
      struck.each_cons(2).map { |before, after| after - before }
    ensure
      core&.destroy
    end
  end

  # The 64 by 64 map, its view put at each of VIEW_SPOTS in turn, a pass each.
  private def jumping_game
    cells = CELLS
    places = CELL_PLACES
    palette = PALETTE
    spots = VIEW_SPOTS
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      colors :palette_0, palette
      pictures = cells.uniq.to_h do |cell|
        image :"cell_#{cell}", width: 8, height: 8, places: places[cell], colors: :palette_0
        [:"cell_#{cell}", :"cell_#{cell}"]
      end
      tiles :island_tiles, pictures
      island = background :island, tiles: :island_tiles, map: cells.each_slice(ACROSS).map { |row| row.map { |cell| :"cell_#{cell}" } }
      pass = var :pass, 0
      game_loop do
        pass += 1
        spots.each_with_index { |(x, y), at| island.scroll_to(x, y) if pass == at + 1 }
      end
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = :gbc }
  end

  # A made-up Color original: its colours, its tiles, and the map, a cell three bytes: the tile's
  # number, low byte first, then its bank of colours.
  private def arrival_original(folder)
    copy = "\0".b * (TILES_AT + (DIFFERENT_CELLS * 16))
    copy[COLORS_AT, PALETTE.length * 2] = PALETTE.pack("v*")
    copy[MAP_AT, CELLS.length * 3] = CELLS.map { |tile| [tile, 0].pack("vC") }.join
    copy[TILES_AT, DIFFERENT_CELLS * 16] = CELL_PLACES.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    path = File.join(folder, "made_up_color.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A title scene and then, from CHANGE_PASS, a map scene of 64 by 64 cells, a tune striking a note
  # every NOTE_FRAMES frames across the change: the cells drawn by hand, or with +pack_from+ read
  # from that original's data pack.
  private def scene_game(pack_from: nil)
    notes = Array.new(80) { |at| VBlank::Audio::Score::Note.new(at: at * NOTE_FRAMES, key: at.even? ? :C4 : :E4, length: NOTE_FRAMES) }
    tune = VBlank::Audio::Score.new(parts: [VBlank::Audio::Score::Part.new(notes: notes)], tempo: 150, ticks_per_beat: 24, length: 80 * NOTE_FRAMES)
    cells = CELLS
    places = CELL_PLACES
    palette = PALETTE
    VBlank.game("BIG MAP", consoles: %i[gbc]) do
      screen :tiled
      enable_sound
      music = songs :music, [tune]
      if pack_from
        pack = data_pack from: pack_from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: DIFFERENT_CELLS
          slots.colors :palette, at: COLORS_AT, count: PALETTE.length
          slots.map_cells :map, count: cells.length
          slots.fill_from_copy do |copy, filled|
            repeat(cells.length) do |at|
              cell = MAP_AT + (at * 3)
              filled[:map].write_cell(at, tile: copy.byte(cell) + (copy.byte(cell + 1) * 256), bank: copy.byte(cell + 2))
            end
          end
        end
      else
        colors :palette_0, palette
        pictures = cells.uniq.to_h do |cell|
          image :"cell_#{cell}", width: 8, height: 8, places: places[cell], colors: :palette_0
          [:"cell_#{cell}", :"cell_#{cell}"]
        end
        tiles :island_tiles, pictures
      end
      state = var :state, 0
      pass = var :pass, 0
      music.play 0
      scene(:title) {}
      scene(:map) do
        if pack_from
          background :island, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS
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
