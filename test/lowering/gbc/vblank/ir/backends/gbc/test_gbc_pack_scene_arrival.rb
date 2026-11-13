# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"
require "stringio"

# A SCENE WHOSE BACKGROUND COMES FROM THE DATA PACK ARRIVES IN ONE FRAME, however many other scenes
# draw theirs from the pack, as the same screens drawn by hand do. A Color original's screen is a map
# of 20 by 18 cells over a few hundred tiles of its own, and its game brings a screen in within the
# frame it takes over. Two such screens whose tiles fit in the Color together are put up with the
# display on, in the blank, as many rows as it holds.
#
# A game that fades (+fading+) changes its colours on every pass, as a screen fading in or held
# white has them drawn every pass, so the blank a screen arrives in sends its colours too. Beside
# them and the sprites the blank holds fewer than a screen's 18 rows; the rows it cannot hold go in
# with the display off for the end of that blank, as a screen bringing its own tiles does, and the
# screen is shown on the frame it takes over.
class TestGBCPackSceneArrival < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # The passes each screen takes over on.
  FIRST_PASS = 10
  SECOND_PASS = 30
  # The frames profiled: from before the first takes over to after the second has.
  PROFILED_FRAMES = FIRST_PASS..(SECOND_PASS + 15)
  ACROSS = 20
  # Each screen's rows: the second is shorter, so the rows of the first past it must go.
  SCREEN_ROWS = [18, 12].freeze
  CELLS = ACROSS * SCREEN_ROWS.max
  # Each screen's different tiles: two screens' fit in the Color's 512 together, so neither brings
  # its own in with the display off (GBC::Art::Room).
  SCREEN_TILES = 200
  TILE_COUNT = 2 * SCREEN_TILES
  BANKS = 4
  BANK_SIZE = 4
  MAP_AT = 0x40
  COLORS_AT = 0x10
  TILES_AT = 0x1000

  # Each tile's places, no two tiles alike, every tile drawing something.
  TILE_PLACES = Array.new(TILE_COUNT) do |tile|
    Array.new(64) { |at| 1 + ((((tile + 1) >> (at % 10)) + (at * 3) + tile) % 3) }
  end
  # Screen +screen+'s cells: each a tile of its own SCREEN_TILES, and its bank.
  SCREEN_CELLS = SCREEN_ROWS.each_with_index.map do |rows, screen|
    Array.new(ACROSS * rows) { |at| [(screen * SCREEN_TILES) + ((at * 7) % SCREEN_TILES), (at / ACROSS) % BANKS] }
  end
  PALETTE = Array.new(BANKS * BANK_SIZE) { |at| ((at * 997) + 0x0421) & 0x7FFF }.freeze
  NOTHING_PRESSED = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: ARRIVAL 0x00000000
    starts from: power-on
  TAPE

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # The profile of each frame says whether a new picture went up in it, and none from the first
  # scene taking over to the second is held, though the colours change as each arrives.
  def test_no_frame_holds_the_picture_as_each_fading_scene_from_the_pack_takes_over
    Dir.mktmpdir do |folder|
      result = color_rom(scene_game(%i[pack pack], folder, fading: true)).profile(out: StringIO.new, tape: NOTHING_PRESSED, frames: PROFILED_FRAMES)

      assert_empty result.held.map { |reading| [reading.frame, reading.picture_held_by] }
    end
  end

  # POWER-ON DOES NOT GROW WITH WHAT LATER SCENES DRAW. The tiles of every scene's background are
  # copied in while the screen is off at power-on, so a second screen's tiles in the pack must not
  # hold the game's first picture a frame later than the game with one.
  def test_the_first_picture_is_not_held_by_a_second_screens_tiles
    shown = [%i[none pack], %i[pack pack]].map { |hows| Dir.mktmpdir { |folder| first_picture_frame(scene_game(hows, folder)) } }

    assert_equal shown.first, shown.last
  end

  def test_each_scene_from_the_pack_arrives_in_one_frame_beside_another
    Dir.mktmpdir do |folder|
      run = arrival_run(scene_game(%i[pack pack], folder))

      assert_equal [1, 1], [run.frames_took(FIRST_PASS + 1), run.frames_took(SECOND_PASS + 1)]
    end
  end

  def test_each_fading_scene_from_the_pack_arrives_in_one_frame
    Dir.mktmpdir do |folder|
      run = arrival_run(scene_game(%i[pack pack], folder, fading: true))

      assert_equal [1, 1], [run.frames_took(FIRST_PASS + 1), run.frames_took(SECOND_PASS + 1)]
    end
  end

  def test_the_same_fading_scenes_drawn_by_hand_arrive_in_one_frame_each
    Dir.mktmpdir do |folder|
      run = arrival_run(scene_game(%i[by_hand by_hand], folder, fading: true))

      assert_equal [1, 1], [run.frames_took(FIRST_PASS + 1), run.frames_took(SECOND_PASS + 1)]
    end
  end

  def test_a_scene_from_the_pack_arrives_in_one_frame_alone
    Dir.mktmpdir do |folder|
      run = arrival_run(scene_game(%i[none pack], folder))

      assert_equal 1, run.frames_took(SECOND_PASS + 1)
    end
  end

  def test_the_same_scenes_drawn_by_hand_arrive_in_one_frame_each
    Dir.mktmpdir do |folder|
      run = arrival_run(scene_game(%i[by_hand by_hand], folder))

      assert_equal [1, 1], [run.frames_took(FIRST_PASS + 1), run.frames_took(SECOND_PASS + 1)]
    end
  end

  # The shorter screen after the taller shows nothing below its own rows, as the interpreter does.
  def test_scenes_from_the_pack_arriving_agree_with_the_interpreter
    Dir.mktmpdir do |folder|
      GBC::CheckedRun.new.run(scene_game(%i[pack pack], folder).program(console: :gbc), frames: SECOND_PASS + 4)
    end
    pass
  end

  # ...and put up with the display off for the rows the blank cannot hold.
  def test_fading_scenes_from_the_pack_arriving_agree_with_the_interpreter
    Dir.mktmpdir do |folder|
      GBC::CheckedRun.new.run(scene_game(%i[pack pack], folder, fading: true).program(console: :gbc), frames: SECOND_PASS + 4)
    end
    pass
  end

  # The frame from power-on the game's first picture went up on. Frame 1 is left out: it is read
  # against work memory as the console powers on, before the start-up clears it.
  private def first_picture_frame(game)
    profile = color_rom(game).profile(out: StringIO.new, tape: NOTHING_PRESSED, frames: 1..FIRST_PASS)
    profile.readings.drop(1).find(&:new_picture?)&.frame
  end

  private def color_rom(game) = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)

  private def arrival_run(game) = GBC::HeadlessRun.new.run(game.program(console: :gbc), frames: SECOND_PASS + 4)

  # A made-up Color original: its colours, its tiles, and each screen's map, a cell three bytes:
  # the tile's number, low byte first, then its bank of colours.
  private def arrival_original(folder)
    copy = "\0".b * (TILES_AT + (TILE_COUNT * 16))
    copy[COLORS_AT, PALETTE.length * 2] = PALETTE.pack("v*")
    SCREEN_CELLS.each_with_index do |cells, screen|
      copy[MAP_AT + (screen * CELLS * 3), cells.length * 3] = cells.map { |tile, bank| [tile, bank].pack("vC") }.join
    end
    copy[TILES_AT, TILE_COUNT * 16] = TILE_PLACES.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    path = File.join(folder, "made_up_color.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A blank scene, then from FIRST_PASS the first screen and from SECOND_PASS the second. +hows+
  # says how each screen is drawn: :pack, from the data pack; :by_hand, its cells as pictures the
  # game declares; :none, an empty scene. With +fading+ the screen is faded half way to white on
  # every other pass, so its colours change on every pass.
  private def scene_game(hows, folder, fading: false)
    from = arrival_original(folder)
    VBlank.game("ARRIVAL", consoles: %i[gbc]) do
      screen :tiled
      if hows.include?(:pack)
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: TILE_COUNT
          slots.colors :palette, at: COLORS_AT, count: PALETTE.length
          SCREEN_CELLS.each_with_index { |cells, screen| slots.map_cells :"map_#{screen}", count: cells.length }
          slots.fill_from_copy do |copy, filled|
            SCREEN_CELLS.each_with_index do |cells, screen|
              repeat(cells.length) do |at|
                cell = MAP_AT + (screen * CELLS * 3) + (at * 3)
                filled[:"map_#{screen}"].write_cell(at, tile: copy.byte(cell) + (copy.byte(cell + 1) * 256), bank: copy.byte(cell + 2))
              end
            end
          end
        end
      end
      if hows.include?(:by_hand)
        PALETTE.each_slice(BANK_SIZE).with_index { |bank, at| colors :"palette_#{at}", bank }
        SCREEN_CELLS.each_index do |screen|
          pictures = SCREEN_CELLS[screen].uniq.to_h do |tile, bank|
            name = :"tile #{tile} #{bank}"
            image name, width: 8, height: 8, places: TILE_PLACES[tile], colors: :"palette_#{bank}"
            [name, name]
          end
          tiles :"screen_#{screen}", pictures
        end
      end
      state = var :state, 0
      pass = var :pass, 0
      scene(:blank) {}
      hows.each_with_index do |how, screen|
        scene(:"screen_#{screen}") do
          case how
          when :pack
            background :"screen_#{screen}", tiles: pack[:video], map: pack[:"map_#{screen}"], colors: pack[:palette], across: ACROSS
          when :by_hand
            map = SCREEN_CELLS[screen].map { |tile, bank| :"tile #{tile} #{bank}" }.each_slice(ACROSS).to_a
            background :"screen_#{screen}", tiles: :"screen_#{screen}", map: map
          end
        end
      end
      game_loop do
        pass += 1
        fade :white, (pass % 2) * 50 if fading
        state = 1 if pass == FIRST_PASS
        state = 2 if pass == SECOND_PASS
        case_var(:state) do
          when_val 0, :blank
          when_val 1, :screen_0
          when_val 2, :screen_1
        end
      end
    end
  end
end
