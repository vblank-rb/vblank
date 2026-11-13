# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"

# The games these tests play, shared with the Advance cartridge's own test of the same lists
# (test/lowering/gba/vblank/builder/test_pack_color_lists_cartridge.rb).
module PackColorListGames
  include SharedConstants
  include MadeUpOriginalLayouts

  GENESIS = LAYOUTS.find { |layout| layout.platform == :genesis }
  BANK_SIZE = 4
  BANKS = Ractor.make_shareable(PALETTE.each_slice(BANK_SIZE).to_a)
  NAMES = %i[bank_0 bank_1 bank_2 bank_3].freeze

  # An 8x8 ship in three stripes, places 1, 2 and 3 from the left, so each colour of a bank shows
  # at a column of its own.
  SHIP = Array.new(64) { |at| [1, 1, 1, 2, 2, 2, 3, 3].fetch(at % 8) }.freeze
  # A column of each stripe, from the ship's left edge.
  STRIPES = [1, 4, 7].freeze
  SHIP_AT = [40, 40].freeze
  BACKDROP_AT = [100, 100].freeze

  # The pack of the made-up original +from+: its sixteen colours in one slot.
  private def palette_pack(builder, from, count: 16)
    builder.data_pack(from: from, version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: count
      slots.numbers :speeds, at: SPEEDS_AT, count: 8, width: :half, signed: false
    end
  end

  # The four banks as lists taken from the pack of +from+.
  private def banks_from_pack(from)
    lambda do |builder|
      pack = palette_pack(builder, from)
      Array.new(BANKS.length) { |bank| pack[:palette].bank(bank, size: BANK_SIZE) }
    end
  end

  # The four banks written in the game.
  private def banks_written_out = ->(_builder) { BANKS }

  # THE GAME: a ship drawn in bank 0's list and with that list alone, which is told to hold bank
  # 1, 2 and 3 on passes 1, 2 and 3 (the ship's column counts the passes) and its own colours
  # after. The backdrop is the first colour of bank 3's list.
  private def recoloring_game(banks, options: VBlank::Cartridge::Options.new) = recoloring_game_and_file(banks, options: options).first

  # The game built as +options+ say, and the pack file its build made (nil for a game with no
  # pack, or a build that leaves its pack out).
  private def recoloring_game_and_file(banks, options: VBlank::Cartridge::Options.new)
    builder = Builder.new(options: options)
    builder.instance_eval do
      NAMES.zip(banks.call(self)) { |name, bank| colors name, bank }
      screen :tiled, backdrop: :bank_3
      image :ship, width: 8, height: 8, colors: :bank_0, places: SHIP
      ship = sprite :ship, at: SHIP_AT
      ship.draw_with :bank_0
      game_loop do
        ship.x += 1
        recolor :bank_0, NAMES.drop(1), showing: ship.x - (SHIP_AT.first + 1)
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  # A GAME WHOSE SPRITE DRAWS WITH A WHOLE SLOT: a ship drawn in a list of the game's own and
  # with the list that is the slot's first +count+ colours. The program and the pack file.
  private def whole_slot_game_and_file(from, options: VBlank::Cartridge::Options.new)
    test = self
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :tiled
      pack = test.palette_pack_of(self, from)
      colors :drawn, [:transparent, :red, :green, :blue]
      colors :whole, pack[:palette]
      image :ship, width: 8, height: 8, colors: :drawn, places: SHIP
      ship = sprite :ship, at: SHIP_AT
      ship.draw_with :whole
      game_loop { wait_vblank }
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  # A GAME THAT WALKS A LIST FROM THE PACK UP FROM WHITE: a ship drawn in a list of the game's own
  # and with a list that holds each step of the walk in turn, a pass a step. The steps are made
  # from the list's colours, which a build that leaves its pack out learns as the game starts.
  WALK_STEPS = 6
  # A walk up from black whose channels wait for a count that starts at 32 and falls by 2 a step
  # (Builder#color_walk's count:), and how many steps it takes.
  COUNTED_WALK = { from: :black, step: 2, count: 32 }.freeze
  COUNTED_WALK_STEPS = 17

  # +counted+ walks by COUNTED_WALK in place of WALK_STEPS steps from white.
  private def walking_game_and_file(from, options: VBlank::Cartridge::Options.new, counted: false)
    test = self
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :tiled
      pack = test.palette_pack_of(self, from)
      colors :shown, [:transparent, :red, :green, :blue]
      colors :bank_2, pack[:palette].bank(2, size: BANK_SIZE)
      image :ship, width: 8, height: 8, colors: :shown, places: SHIP
      ship = sprite :ship, at: SHIP_AT
      ship.draw_with :shown
      walk = counted ? color_walk(:bank_2, **COUNTED_WALK) : color_walk(:bank_2, from: :white, steps: WALK_STEPS)
      step = var :step, 0
      game_loop do
        recolor :shown, walk, showing: step
        step.store!(step + 1)
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  # A picture drawn in a list from the pack and blitted, where no sprite or `recolor` is.
  private def blitting_game_and_file(from, options: VBlank::Cartridge::Options.new)
    test = self
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :bitmap
      pack = test.palette_pack_of(self, from)
      colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
      image :ship, width: 8, height: 8, colors: :bank_1, places: SHIP
      game_loop do
        clear_screen :black
        blit :ship, 20, 20
        blit mirror(:ship), 40, 20
        wait_vblank
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  # Called back from a game block, where `self` is the builder.
  def palette_pack_of(builder, from, count: 16) = palette_pack(builder, from, count: count)
end

# A LIST OF COLOURS WHOSE COLOURS COME FROM A SLOT OF THE DATA PACK (`colors :name, pack[:slot]`,
# or one bank of the slot). A retail game repaints a sprite by writing other colours over its
# palette, and the colours it writes are data of the player's copy, so a port names each set as a
# list from the pack and tells one list to hold them in turn.
#
# The answer key is the made-up original's own palette (MadeUpOriginalLayouts::PALETTE, kept the
# way the Genesis keeps colours): bank +n+ of four is its colours 4n to 4n + 3, and the same game
# with those colours written in it must show the same picture. The same games built with the pack
# left out are test/pack_color_list_at_start_tests.rb's.
class TestPackColorLists < Minitest::Test
  include PackColorListGames

  # The ship's three stripes once pass +pass+ is drawn (Testing#framework_drawing_lag), when it
  # has moved +pass+ pixels.
  private def stripes_after(program, pass)
    screen = game_player.run(program, frames: pass + framework_drawing_lag).screen
    STRIPES.map { |column| screen.pixel(SHIP_AT.first + pass + column, SHIP_AT.last + 1) }
  end

  private def shown_all(colors) = colors.map { |color| shown(color) }

  def test_a_sprite_recolored_through_three_banks_of_a_slot_shows_the_colors_of_each
    Dir.mktmpdir do |folder|
      program = recoloring_game(banks_from_pack(layout_original(folder, GENESIS)))

      (1..3).each do |pass|
        assert_equal shown_all(BANKS.fetch(pass).drop(1)), stripes_after(program, pass), "pass #{pass} shows bank #{pass}"
      end
      assert_equal shown_all(BANKS.first.drop(1)), stripes_after(program, 4), "a number past the banks is the list's own colors"
    end
  end

  # A list's first place is see-through to a picture and the colour shown to a backdrop, as it is
  # for a list written in the game.
  def test_a_backdrop_shows_the_first_color_of_a_list_from_the_pack
    Dir.mktmpdir do |folder|
      program = recoloring_game(banks_from_pack(layout_original(folder, GENESIS)))

      assert_equal shown(BANKS.fetch(3).first), game_player.run(program, frames: 3).screen.pixel(*BACKDROP_AT)
    end
  end

  def test_a_game_with_lists_from_the_pack_plays_as_one_with_the_colors_written_in_it
    Dir.mktmpdir do |folder|
      packed = recoloring_game(banks_from_pack(layout_original(folder, GENESIS)))
      written = recoloring_game(banks_written_out)

      (1..6).each do |frames|
        assert_equal game_player.run(written, frames: frames).screen.to_a, game_player.run(packed, frames: frames).screen.to_a,
                     "after #{frames} frames the two games show the same picture"
      end
    end
  end

  # A whole slot is a list too, where it holds no more colours than a list does.
  def test_a_whole_slot_is_a_list_a_sprite_draws_with
    Dir.mktmpdir do |folder|
      program, = whole_slot_game_and_file(layout_original(folder, GENESIS))
      screen = game_player.run(program, frames: 3).screen

      assert_equal shown_all(PALETTE[1, 3]), STRIPES.map { |column| screen.pixel(SHIP_AT.first + column, SHIP_AT.last + 1) }
    end
  end

  def test_a_slot_of_more_colors_than_a_list_holds_is_refused_naming_bank
    Dir.mktmpdir do |folder|
      builder = Builder.new
      pack = palette_pack(builder, layout_original(folder, GENESIS), count: 32)
      error = assert_raises(ArgumentError) { builder.colors :whole, pack[:palette] }

      assert_includes error.message, "bank"
      assert_includes error.message, "32 colors"
    end
  end

  def test_a_slot_that_does_not_hold_colors_is_refused
    Dir.mktmpdir do |folder|
      builder = Builder.new
      pack = palette_pack(builder, layout_original(folder, GENESIS))
      error = assert_raises(ArgumentError) { builder.colors :speeds, pack[:speeds] }

      assert_includes error.message, "a slot of colors"
    end
  end
end
