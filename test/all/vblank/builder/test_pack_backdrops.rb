# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# The games these tests play, shared with the tests of a scene's own backdrop from the pack
# (test/console/gba/vblank/builder/test_pack_backdrops_on_the_advance.rb) and of the Advance's
# cartridge (test/lowering/gba/vblank/builder/test_pack_backdrops_cartridge.rb).
module PackBackdropGames
  include SharedConstants

  # Two banks of sixteen colours whose first colours are not black and differ, each a colour the
  # Genesis shows exactly. An original keeps a real colour in the first place of a bank: the
  # console shows the first bank's wherever no tile draws.
  BANKS = Ractor.make_shareable([MadeUpOriginalLayouts::PALETTE.rotate(5), MadeUpOriginalLayouts::PALETTE.rotate(9)])
  # One tile, see-through in its left half and a stripe of places 1 to 3 in its right, so the
  # Game Boy Color can show it too.
  TILE = Ractor.make_shareable((0...64).map { |at| at % 8 < 4 ? 0 : 1 + ((at % 8) % 3) })

  TILES_AT = 0x100
  COLORS_AT = 0x40
  MAP_AT = 0x20

  # Where nothing is drawn, a see-through pixel of the one cell, and a drawn pixel of it.
  EMPTY = [100, 100].freeze
  SEE_THROUGH = [1, 1].freeze
  DRAWN = [5, 1].freeze
  DRAWN_PLACE = TILE.fetch((DRAWN.last * 8) + DRAWN.first)

  # A made-up Advance original: one tile, a map of one cell drawn from bank 0, and the two banks.
  private def backdrop_original(folder)
    tile = TILE.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*")
    copy = "\0".b * (TILES_AT + 64)
    copy[COLORS_AT, 64] = BANKS.flatten.pack("v*")
    copy[MAP_AT, 2] = [1].pack("v")
    copy[TILES_AT + 32, 32] = tile
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path },
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The pack of that original, declared on +builder+.
  private def backdrop_pack(builder, from)
    builder.data_pack(from: from, version: "1") do |slots|
      slots.tiles :video, at: TILES_AT, count: 2
      slots.numbers :map, at: MAP_AT, count: 1, width: :half, signed: false
      slots.colors :palette, at: COLORS_AT, count: 32
    end
  end

  # The background +name+ of the pack's one cell, declared on +builder+.
  private def pack_cell(builder, pack, name)
    builder.background name, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 1, cell: 8
  end

  # A game whose own `screen` line is given what +screen_options+ makes of the pack, showing the
  # pack's one cell.
  private def game_with_backdrop(from, &screen_options)
    test = self
    b = Builder.new
    b.instance_eval do
      pack = test.backdrop_pack_of(self, from)
      screen :tiled, **instance_exec(pack, &screen_options)
      test.pack_cell_of(self, pack, :world)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # THREE SCENES UNDER A TINT. The logos say their backdrop is the pack's first colour, the title
  # that it is the second bank's, and the menu says none, so it shows the game's, black. A tint
  # toward red starts full and lifts by a tenth each pass, as a game fades its first screen in;
  # the title arrives on pass +TITLE_PASS+ while the tint is still in force, and the menu on pass
  # +MENU_PASS+, after it has lifted.
  TITLE_PASS = 6
  MENU_PASS = 14
  TINT_LIFTED_PASS = 10

  # +written_out+ gives the logos' and the title's `screen` lines the two colours written in the
  # game, where they are otherwise taken from the pack.
  private def scenes_with_backdrops(from, written_out: false)
    scenes_under(from, written_out: written_out) do |level|
      level.store!((level - 10).clamp(0, 100))
      tint :red, level
    end
  end

  # The same scenes under a tint that holds still, so nothing but a scene arriving writes colours.
  private def scenes_under_a_held_tint(from) = scenes_under(from) { |_level| tint :red, 50 }

  # The same scenes under a tint for the first passes and a fade toward black from pass
  # +FADE_PASS+ on, which takes the tint's place while the logos are still up.
  FADE_PASS = 3

  private def scenes_under_a_tint_then_a_fade(from)
    scenes_under(from) do |level|
      level.store!(level + 1)
      if level < 100 + FADE_PASS
        tint :red, 50
      else
        fade :black, 25
      end
    end
  end

  # The three scenes, the block run on each pass before the scene is, with the variable `level`,
  # which starts at 100.
  private def scenes_under(from, written_out: false, &each_pass)
    test = self
    b = Builder.new
    b.instance_eval do
      screen :tiled
      pack = test.backdrop_pack_of(self, from)
      state = var :state, 0
      level = var :level, 100
      tick = 0
      logos_backdrop, title_backdrop = written_out ? [BANKS[0][0], BANKS[1][0]] : [pack[:palette], pack[:palette].bank(1)]
      scene(:logos) do
        screen :tiled, backdrop: logos_backdrop
        test.pack_cell_of(self, pack, :logos)
      end
      scene(:title) do
        screen :tiled, backdrop: title_backdrop
        test.pack_cell_of(self, pack, :title)
      end
      scene(:menu) { test.pack_cell_of(self, pack, :menu) }
      game_loop do
        tick += 1
        instance_exec(level, &each_pass)
        state = 1 if tick == TITLE_PASS
        state = 2 if tick == MENU_PASS
        case_var(:state) do
          when_val 0, :logos
          when_val 1, :title
          when_val 2, :menu
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Called back from a game block, where `self` is the builder.
  def backdrop_pack_of(builder, from) = backdrop_pack(builder, from)
  def pack_cell_of(builder, pack, name) = pack_cell(builder, pack, name)
end

# A SCREEN'S BACKDROP TAKEN FROM THE DATA PACK (`screen :tiled, backdrop: pack[:palette]`). A retail
# game's screen shows, wherever none of its tiles draws, the first colour of the colours it loaded,
# and that colour is data of the player's copy. So a port says the backdrop is the slot's first
# colour, or a bank's, or another place of either.
#
# The answer key is the made-up original's own colours (PackBackdropGames::BANKS). A scene's own
# backdrop is in test/console/gba/, as a scene's own backdrop of a colour is.
class TestPackBackdrops < Minitest::Test
  include PackBackdropGames

  READS_PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  private def screen_of(program) = game_player.run(program, frames: 4).screen

  def test_a_backdrop_from_a_slot_shows_its_first_color_where_no_tile_draws
    Dir.mktmpdir do |folder|
      screen = screen_of(game_with_backdrop(backdrop_original(folder)) { |pack| { backdrop: pack[:palette] } })

      assert_equal shown(BANKS[0][0]), screen.pixel(*EMPTY), "an empty cell"
      assert_equal shown(BANKS[0][0]), screen.pixel(*SEE_THROUGH), "a see-through pixel of a tile"
      assert_equal shown(BANKS[0][DRAWN_PLACE]), screen.pixel(*DRAWN), "a drawn pixel is as drawn"
    end
  end

  def test_a_backdrop_from_a_bank_shows_the_first_color_of_the_bank
    Dir.mktmpdir do |folder|
      screen = screen_of(game_with_backdrop(backdrop_original(folder)) { |pack| { backdrop: pack[:palette].bank(1) } })

      assert_equal shown(BANKS[1][0]), screen.pixel(*EMPTY)
    end
  end

  def test_backdrop_place_picks_another_color_of_the_slot
    Dir.mktmpdir do |folder|
      program = game_with_backdrop(backdrop_original(folder)) { |pack| { backdrop: pack[:palette], backdrop_place: 19 } }

      assert_equal shown(BANKS[1][3]), screen_of(program).pixel(*EMPTY)
    end
  end

  def test_a_game_with_a_backdrop_from_the_pack_plays_as_one_with_the_color_written_in_it
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      packed = game_with_backdrop(from) { |pack| { backdrop: pack[:palette] } }
      written = game_with_backdrop(from) { |_pack| { backdrop: BANKS[0][0] } }

      assert_equal screen_of(written).to_a, screen_of(packed).to_a
    end
  end

  def test_a_place_the_slot_does_not_have_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder)) { |pack| { backdrop: pack[:palette].bank(1), backdrop_place: 16 } }
      end

      assert_includes error.message, "backdrop_place: 16"
      assert_includes error.message, "0 to 15"
    end
  end

  def test_a_slot_that_does_not_hold_colors_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder)) { |pack| { backdrop: pack[:map] } }
      end

      assert_includes error.message, "a slot of colors"
    end
  end

  # A build that leaves its pack out cannot know the colour while it builds.
  def test_a_build_reading_its_pack_as_it_starts_is_told_it_is_not_made_yet
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = backdrop_pack(builder, backdrop_original(folder))
      error = assert_raises(ArgumentError) { builder.screen :tiled, backdrop: pack[:palette] }

      assert_includes error.message, "backdrop:"
      assert_includes error.message, "not made that way yet"
    end
  end
end
