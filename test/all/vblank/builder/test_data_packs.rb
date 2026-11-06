# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# A PORT READS THE ORIGINAL'S DATA THROUGH A DATA PACK (`data_pack`). The game says which slots
# the pack holds, each a known shape and size, and where in the player's copy each comes from; the
# build makes the pack from the copy, and the game's pictures and tables read the pack. The game
# holds handles on the slots, never what they hold: `image` and `table` read a slot given one.
#
# The original here is made up: a few hundred bytes this file writes itself, in the shapes a Game
# Boy Advance cartridge keeps its data in, with a SHA-1 worked out from them. The answer key is
# the same game holding the same data itself, written from the numbers the made-up original was
# written from, so the two can only agree if the pack is cut and read right.
class TestDataPacks < Minitest::Test
  # Sixteen colours: place 0 see-through, then red, green, blue, white and a run of greys.
  PALETTE = [0x0000, 0x001F, 0x03E0, 0x7C00, 0x7FFF, *(1..11).map { |grey| grey * 0x0421 }].freeze
  # Two 8x8 tiles as their places: stripes of three colours, and a diagonal over two greys. Each
  # keeps to three colours, so it fits a Game Boy Color's square of four with black.
  TILE_PLACES = [(0...64).map { |at| 1 + ((at + (at / 8)) % 3) },
                 (0...64).map { |at| (at % 8) == (at / 8) ? 4 : 5 + (at % 2) }].freeze
  SPEEDS = [10, 30, 50, 70, 90, 110, 130, 150].freeze

  PALETTE_AT = 0x10
  TILES_AT = 0x40
  SPEEDS_AT = 0xA0
  NUDGES_AT = 0xB0
  COPY_SIZE = 0x140

  # The made-up original: filler bytes, with the colours, the tiles (two pixels a byte, the left
  # one in the low half) and the table written where the port's slots say they are.
  COPY = begin
    bytes = (0...COPY_SIZE).map { |at| (at * 37 + 11) & 0xFF }.pack("C*")
    bytes[PALETTE_AT, 32] = PALETTE.pack("v*")
    tiles = TILE_PLACES.flatten.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*")
    bytes[TILES_AT, tiles.bytesize] = tiles
    bytes[SPEEDS_AT, SPEEDS.length] = SPEEDS.pack("C*")
    bytes[NUDGES_AT, 2] = [0xF6, 0x0A].pack("C*")
    bytes.freeze
  end
  SHA1 = Digest::SHA1.hexdigest(COPY)

  private def original(folder)
    path = File.join(folder, "made_up.gba")
    File.binwrite(path, COPY)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path },
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # The game: the two tiles laid out as a background, and a marker whose place across the screen
  # is read from the table each frame. +data+ hands over the colours, each tile's places and the
  # table, from the pack or held directly.
  private def game_program(data)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      colors, first, second, speeds = data.call(self)
      image :wall_a, width: 8, height: 8, colors: colors, places: first
      image :wall_b, width: 8, height: 8, colors: colors, places: second
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      step = var :step, 0
      game_loop do
        wait_vblank
        draw_rect_at speeds[step], 40, 4, 4, :white
        step = (step + 1) & 7
      end
    end
    b.finalize_program
    b.program
  end

  private def made_up_pack(builder, folder)
    builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: 16
      slots.tiles :walls, at: TILES_AT, count: 2
      slots.numbers :speeds, at: SPEEDS_AT, count: 8, width: :byte, signed: false
    end
  end

  private def through_pack(folder)
    lambda do |builder|
      pack = made_up_pack(builder, folder)
      [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:speeds])]
    end
  end

  private def held_directly
    lambda do |builder|
      [PALETTE, TILE_PLACES[0], TILE_PLACES[1], builder.table(:speeds, SPEEDS, width: :byte, signed: false)]
    end
  end

  def test_a_game_reading_its_tiles_and_table_through_the_pack_plays_as_one_holding_them
    Dir.mktmpdir do |folder|
      packed = game_program(through_pack(folder))
      held = game_program(held_directly)

      [1, 4, 9].each do |frames|
        assert_equal game_player.run(held, frames: frames).screen.to_a, game_player.run(packed, frames: frames).screen.to_a,
                     "after #{frames} frames the two games show the same picture"
      end
    end
  end

  def test_the_pack_names_the_copy_it_was_made_from_and_its_build
    Dir.mktmpdir do |folder|
      pack = Builder.new.data_pack(from: original(folder), version: "0.3") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
      end

      assert_equal SHA1, pack.rom_sha1
      assert_equal "0.3", pack.build_version
    end
  end

  # A handle says the slot's shape and size, and nothing it holds.
  def test_a_slot_handle_says_its_shape_and_size
    Dir.mktmpdir do |folder|
      pack = made_up_pack(Builder.new, folder)

      assert_equal :tiles, pack[:walls].shape
      assert_equal 2, pack[:walls].count
      assert_equal 1, pack[:walls].tile(1).count
      assert_equal 64, pack[:walls].layout.byte_size
    end
  end

  def test_a_data_pack_must_say_its_version
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) do
        Builder.new.data_pack(from: original(folder)) { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
      end

      assert_match "needs version:", refused.message
    end
  end

  def test_a_table_line_whose_width_is_not_the_slots_is_refused
    Dir.mktmpdir do |folder|
      builder = Builder.new
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) { builder.table(:speeds, pack[:speeds], width: :half) }

      assert_match "the slot sets the width", refused.message
    end
  end

  def test_an_image_given_a_whole_slot_of_tiles_for_its_places_is_refused
    Dir.mktmpdir do |folder|
      builder = Builder.new
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) do
        builder.image(:wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls])
      end

      assert_match "one tile", refused.message
    end
  end

  def test_a_slot_the_pack_does_not_hold_is_a_friendly_error
    Dir.mktmpdir do |folder|
      pack = made_up_pack(Builder.new, folder)
      refused = assert_raises(ArgumentError) { pack[:music] }

      assert_match ":music", refused.message
      assert_match ":palette", refused.message
    end
  end

  def test_a_slot_past_the_end_of_the_copy_is_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::Original::WrongCopy) do
        Builder.new.data_pack(from: original(folder), version: "1") { |slots| slots.tiles :walls, at: COPY_SIZE - 16, count: 1 }
      end

      assert_match ":walls", refused.message
    end
  end

  def test_a_game_has_one_data_pack
    Dir.mktmpdir do |folder|
      builder = Builder.new
      made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) do
        builder.data_pack(from: original(folder), version: "1") { |slots| slots.colors :more, at: 0, count: 1 }
      end

      assert_match "one data pack", refused.message
    end
  end

  def test_a_machine_with_no_copy_stops_saying_what_to_set
    Dir.mktmpdir do |folder|
      nowhere = VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {},
                                           settings_file: File.join(folder, "made_up.yml"),
                                           releases: { "Test" => { "sha1" => SHA1 } })
      refused = assert_raises(VBlank::Original::NotSet) do
        Builder.new.data_pack(from: nowhere, version: "1") { |slots| slots.colors :palette, at: 0, count: 16 }
      end

      assert_match "MADE_UP_ROM", refused.message
    end
  end

  # The slot says whether its numbers can be below zero; the bytes never decide it. 0xF6 is -10 in
  # a slot of signed bytes, so the marker stands ten pixels left of 100.
  def test_a_table_from_a_slot_of_signed_numbers_reads_them_below_zero
    Dir.mktmpdir do |folder|
      from = original(folder)
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        clear_screen :black
        pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :nudges, at: NUDGES_AT, count: 2, width: :byte, signed: true
        end
        nudges = table :nudges, pack[:nudges]
        game_loop do
          wait_vblank
          draw_rect_at nudges[0] + 100, 20, 2, 2, :white
          draw_rect_at nudges[1] + 100, 40, 2, 2, :white
        end
      end
      b.finalize_program
      screen = game_player.run(b.program, frames: 2).screen

      assert_equal Color.resolve(:white), screen.pixel(90, 20), "-10 puts the first marker at 90"
      assert_equal Color.resolve(:white), screen.pixel(110, 40), "10 puts the second at 110"
    end
  end
end
