# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "pack_background_tests"

# A scene whose background map is 64 by 64 cells arrives on its first frame, as the interpreter shows
# it. The screen is a plane of 64 by 64 cells of 8x8 tiles, 8 KB of map, which is what an original's
# 32 by 32 cells of 16x16 come to on a console of 8x8 tiles. The console's own games put a screen like that up in a blank without
# losing a frame, so the pass the scene takes over on takes one frame, and a note the tune strikes
# then is struck on its frame.
class TestGenesisBigMapArrival < Minitest::Test
  include PackBackgroundGames

  Genesis = VBlank::IR::Backends::Genesis

  # The pass the map scene takes over, and how many different tiles the map is made of.
  CHANGE_PASS = 30
  DIFFERENT_CELLS = 256
  ACROSS = 64
  # A note every this many frames.
  NOTE_FRAMES = 3
  # Maps enough to be more than a 128K block of the cartridge.
  MANY_MAPS = 20

  # Each tile's places, none alike, and every place drawn.
  CELL_PLACES = Array.new(DIFFERENT_CELLS) do |cell|
    Array.new(64) { |at| 1 + (((at * 7) + (cell * 13) + (at * cell)) % 15) }
  end
  CELLS = Array.new(ACROSS * ACROSS) { |at| (at * 37) % DIFFERENT_CELLS }

  def test_a_scene_with_a_map_of_64_by_64_cells_arrives_in_one_frame
    run = Genesis::HeadlessRun.new.run(scene_game.program(console: :genesis), frames: CHANGE_PASS + 4)

    assert_equal 1, run.frames_took(CHANGE_PASS + 1)
  end

  def test_a_note_is_struck_on_its_frame_as_a_scene_with_a_big_map_arrives
    gaps = strike_gaps(scene_game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false))

    assert_equal [NOTE_FRAMES], gaps.uniq, "frames between strikes around the change: #{gaps.inspect}"
  end

  def test_a_scene_with_a_big_map_arriving_agrees_with_the_interpreter
    Genesis::CheckedRun.new.run(scene_game.program(console: :genesis), frames: CHANGE_PASS + 4)
    pass
  end

  # The chip counts its copy's source within one 128K block of the cartridge, so a map lying across the
  # end of one goes in as two copies. Twenty maps of 8K are more than a block, and one lies across.
  def test_scenes_whose_maps_lie_across_a_block_of_the_cartridge_agree_with_the_interpreter
    Genesis::CheckedRun.new.run(many_maps_game, frames: MANY_MAPS + 2)
    pass
  end

  # The frames between each note the chips are told and the next, from ten passes before the change
  # to ten after. A note is a change of pitch on either chip: the square voices' wave lengths, or the
  # FM voices' frequencies ($A0 to $A6 of each half).
  private def strike_gaps(rom)
    passes_at = rom.built.runtime.fetch(Genesis::Runtime::Frame::PASSES)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.bin")
      rom.write(path)
      core = VBlank::Console.for(:genesis).open_core(path, save_dir: dir)
      core.run_frame while core.wram_read32(passes_at) < CHANGE_PASS - 10
      pitches = []
      until core.wram_read32(passes_at) >= CHANGE_PASS + 10
        core.run_frame
        pitches << pitches_now(core)
      end
      struck = (1...pitches.length).select { |frame| pitches[frame] != pitches[frame - 1] }
      struck.each_cons(2).map { |before, after| after - before }
    ensure
      core&.destroy
    end
  end

  private def pitches_now(core)
    psg = core.psg_registers
    fm = core.fm_registers.bytes
    [psg[0], psg[2], psg[4], *[0, 256].flat_map { |half| (0xA0..0xA6).map { |register| fm[half + register] } }]
  end

  # A scene a pass, each a map of 64 by 64 cells of its own: CELLS moved on by a cell each, and a
  # view scrolled a row further down each, so the copies start on different rows.
  private def many_maps_game
    cells = CELLS
    places = CELL_PLACES
    count = MANY_MAPS
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      colors :palette_0, BANKS.first
      pictures = cells.uniq.to_h do |cell|
        image :"cell_#{cell}", width: 8, height: 8, places: places[cell], colors: :palette_0
        [:"cell_#{cell}", :"cell_#{cell}"]
      end
      tiles :island_tiles, pictures
      pass = var :pass, 0
      count.times do |map|
        scene(:"map_#{map}") do
          island = background :island, tiles: :island_tiles, map: cells.rotate(map).each_slice(ACROSS).map { |row| row.map { |cell| :"cell_#{cell}" } }
          island.scroll_to 0, map * 8
        end
      end
      game_loop do
        pass += 1
        call count.times.to_h { |map| [map + 1, :"map_#{map}"] }, number: :pass
      end
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = :genesis }
  end

  # A title scene and then, from CHANGE_PASS, a map scene of 64 by 64 cells, a tune
  # striking a note every NOTE_FRAMES frames across the change.
  private def scene_game
    notes = Array.new(80) { |at| VBlank::Audio::Score::Note.new(at: at * NOTE_FRAMES, key: at.even? ? :C4 : :E4, length: NOTE_FRAMES) }
    tune = VBlank::Audio::Score.new(parts: [VBlank::Audio::Score::Part.new(notes: notes)], tempo: 150, ticks_per_beat: 24, length: 80 * NOTE_FRAMES)
    cells = CELLS
    places = CELL_PLACES
    VBlank.game("BIG MAP", consoles: %i[genesis]) do
      screen :tiled
      enable_sound
      music = songs :music, [tune]
      colors :palette_0, BANKS.first
      pictures = cells.uniq.to_h do |cell|
        image :"cell_#{cell}", width: 8, height: 8, places: places[cell], colors: :palette_0
        [:"cell_#{cell}", :"cell_#{cell}"]
      end
      tiles :island_tiles, pictures
      state = var :state, 0
      pass = var :pass, 0
      music.play 0
      scene(:title) {}
      scene(:map) do
        background :island, tiles: :island_tiles, map: cells.each_slice(ACROSS).map { |row| row.map { |cell| :"cell_#{cell}" } }
      end
      game_loop do
        pass += 1
        state = 1 if pass == CHANGE_PASS
        call({ 0 => :title, 1 => :map }, number: :state)
      end
    end
  end
end
