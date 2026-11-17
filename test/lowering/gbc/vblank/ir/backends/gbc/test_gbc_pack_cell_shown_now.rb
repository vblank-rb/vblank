# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A CELL OF A BACKGROUND FROM THE DATA PACK WRITTEN `now: true` SHOWS ON THE FRAME BEING DRAWN, on the
# Color's cartridge, as a cell of a background of the game's own tiles written with `set_tile ...,
# now: true` does. The Color writes its grid only while the display is not reading it, so a cell
# left for the gap between frames shows a frame later; a retail game that writes a light low on
# the screen while the frame is drawn shows it on that frame, and a port held to it frame by frame
# needs the same. The answer key is the cartridge's own `set_tile now: true` on a background of the
# same size, which TestGBCPressToPicture holds to the frame being drawn.
class TestGBCPackCellShownNow < Minitest::Test
  PRESS = 40
  COLS = 20
  ROWS = 18
  # The cells written, low on the screen so the pass writes them before the display reaches them:
  # one written in the game and one worked out as it runs.
  WRITTEN = [3, 16].freeze
  WORKED = [9, 16].freeze

  TILES_AT = 0x100
  COLORS_AT = 0x40
  # The Color original's tiles: 0 draws nothing, 1 is the field and 2 the light.
  VIDEO = [Array.new(64, 0), Array.new(64, 1), Array.new(64, 2)].freeze
  LIGHT = VBlank::Original::MapCell.number(tile: 2, bank: 0)

  # A made-up Color original holding the three tiles and a bank of four colours.
  private def original(folder)
    copy = "\0".b * (TILES_AT + (VIDEO.length * 16))
    copy[COLORS_AT, 8] = MadeUpOriginalLayouts::PALETTE.first(4).pack("v*")
    copy[TILES_AT, VIDEO.length * 16] = VIDEO.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    path = File.join(folder, "made_up_light.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The field from the pack, a map of map cells all tile 1, which on a press of Down has the light
  # written into two cells: by its number, or with +by_place+ by its place in a slot of told cells.
  private def pack_game(folder, now:, by_place: false)
    from = original(folder)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: VIDEO.length
        slots.colors :palette, at: COLORS_AT, count: 4
        slots.map_cells :map, count: COLS * ROWS
        slots.map_cells :changes, count: 2
        slots.fill_from_copy do |_copy, filled|
          repeat(COLS * ROWS) { |at| filled[:map].write_cell(at, tile: 1) }
          filled[:changes].write_cell(0, tile: 1)
          filled[:changes].write_cell(1, tile: 2)
        end
      end
      field = background :field, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: COLS,
                                 set_cells: by_place ? pack[:changes] : [LIGHT]
      light = by_place ? 1 : LIGHT
      worked = var :worked, light
      game_loop do
        if pressed(:down)
          field.set_cell(*WRITTEN, light, now: now)
          field.set_cell(*WORKED, worked, now: now)
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The answer key: the same field and light as tiles of the game's own.
  private def own_game(now:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:field_tile, "#" => :red) { "########\n" * 8 }
      image(:light_tile, "#" => :blue) { "########\n" * 8 }
      tiles :set, "f" => :field_tile, "l" => :light_tile
      field = background :field, tiles: :set, map: Array.new(ROWS) { "f" * COLS }
      game_loop do
        if pressed(:down)
          field.set_tile(*WRITTEN, "l", now: now)
          field.set_tile(*WORKED, "l", now: now)
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The first frame, numbered from 1 at power-on, on which the cell at +at+ shows something other
  # than the field, with Down pressed for frame PRESS.
  private def frame_lit(program, at)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "LIGHT")
    down = VBlank::Console::Hardware::KEY_DOWN
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, keys: ->(played) { played + 1 == PRESS ? down : 0 })
    x = (at[0] * 8) + 4
    y = (at[1] * 8) + 4
    field = nil
    (1..(PRESS + 10)).find do |frame|
      v.step
      field = v.pixel_gba(x, y) if frame == PRESS - 5
      frame > PRESS - 5 && v.pixel_gba(x, y) != field
    end
  end

  def test_a_told_cell_written_now_shows_on_the_frame_a_set_tile_now_does
    Dir.mktmpdir do |folder|
      own_now = frame_lit(own_game(now: true), WRITTEN)

      assert_equal own_now, frame_lit(pack_game(folder, now: true), WRITTEN), "a told number written in the game"
      assert_equal own_now, frame_lit(pack_game(folder, now: true), WORKED), "a told number worked out"
      assert_equal own_now + 1, frame_lit(pack_game(folder, now: false), WRITTEN), "left for the gap, a frame later"
    end
  end

  def test_a_place_in_a_slot_of_told_cells_written_now_shows_on_the_frame_a_set_tile_now_does
    Dir.mktmpdir do |folder|
      own_now = frame_lit(own_game(now: true), WRITTEN)

      assert_equal own_now, frame_lit(pack_game(folder, now: true, by_place: true), WRITTEN), "a place written in the game"
      assert_equal own_now, frame_lit(pack_game(folder, now: true, by_place: true), WORKED), "a place worked out"
      assert_equal own_now + 1, frame_lit(pack_game(folder, now: false, by_place: true), WORKED), "left for the gap, a frame later"
    end
  end

  def test_a_told_cell_written_now_plays_as_the_interpreter_plays_it
    Dir.mktmpdir do |folder|
      [pack_game(folder, now: true), pack_game(folder, now: true, by_place: true)].each do |program|
        game_player.input_each_frame { |frame| frame == 5 ? [:down] : [] }.run(program, frames: 10)
      end
    end
  end
end
