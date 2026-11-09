# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "genesis_packing_answers"
require "made_up_original"

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
  include MadeUpOriginal

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

  # A RELEASE-BY-RELEASE PLACE. The same data sits at different places in two releases; a slot's at:
  # names each, and the routine is handed the release's name. Each release's pack holds the same
  # slots, so the game is built once against it.
  def two_release_pack_from(copy)
    Dir.mktmpdir do |folder|
      builder = Builder.new
      builder.data_pack(from: two_release_original(folder, copy: copy), version: "1") { |slots| two_release_slots(slots) }
      VBlank::Original::Pack.from_bytes(builder.made_data_pack_file)
    end
  end

  def test_each_release_makes_the_same_pack_from_its_own_places
    us = two_release_pack_from(COPY)
    eu = two_release_pack_from(COPY_EU)

    assert_equal SHA1, us.rom_sha1
    assert_equal SHA1_EU, eu.rom_sha1
    assert_equal us.slots, eu.slots
    assert_equal PALETTE.pack("v*"), eu.bytes_of(:palette)
    assert_equal HEIGHTS.pack("C*"), eu.bytes_of(:heights)
  end

  def test_a_release_left_out_of_a_slots_places_is_refused_naming_it
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::BuildError) do
        Builder.new.data_pack(from: two_release_original(folder, copy: COPY), version: "1") do |slots|
          slots.colors :palette, at: { "US" => PALETTE_AT }, count: 16
        end
      end

      assert_match "EU", refused.message
      assert_match ":palette", refused.message
    end
  end

  def test_a_name_that_is_no_release_in_a_slots_places_is_refused_naming_it
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::BuildError) do
        Builder.new.data_pack(from: two_release_original(folder, copy: COPY), version: "1") do |slots|
          slots.colors :palette, at: { "US" => PALETTE_AT, "EU" => PALETTE_AT, "JP" => 0 }, count: 16
        end
      end

      assert_match "JP", refused.message
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

  def test_a_game_reading_slots_its_routine_filled_plays_as_one_holding_them
    Dir.mktmpdir do |folder|
      unpacked = lambda do |builder|
        pack = unpacked_pack(builder, folder)
        [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])]
      end
      held = ->(builder) { [PALETTE, TILE_PLACES[0], TILE_PLACES[1], builder.table(:speeds, HEIGHTS, width: :byte, signed: false)] }

      [1, 5].each do |frames|
        assert_equal game_player.run(game_program(held), frames: frames).screen.to_a,
                     game_player.run(game_program(unpacked), frames: frames).screen.to_a,
                     "after #{frames} frames the two games show the same picture"
      end
    end
  end

  # A plane map unpacked into a Genesis slot of halves keeps each cell high byte first, as the
  # Genesis does, so a table of the slot reads each cell as the map holds it: here the third,
  # spelt out and flipped top to bottom.
  GENESIS_MAP = GenesisPackingAnswers.enigma_block(width: 11, flips: 2, counting: 0x10, repeating: 0) do |ops|
    ops.counting(2)
    ops.same([0x155, true], 2)
  end.freeze

  def test_a_table_of_an_unpacked_genesis_map_reads_its_cells
    Dir.mktmpdir do |folder|
      from = copy_of(folder, GENESIS_MAP + ([0] * 4).pack("C*"), platform: :genesis)
      b = Builder.new
      b.instance_eval do
        pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :map, count: 4, width: :half, signed: false
          slots.fill_from_copy { |copy, filled| copy.unpack_enigma at: 0, into: filled[:map], base: 0x2000 }
        end
        cells = table :cells, pack[:map]
        seen = var :seen, 0
        game_loop do
          wait_vblank
          seen.store!(cells[2])
        end
      end
      b.finalize_program

      assert_equal 0x2000 + 0x1000 + 0x155, game_player.run(b.program, frames: 2)[:seen], "base, flip, then the cell"
    end
  end

  def test_a_slot_with_no_place_and_no_routine_is_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) do
        Builder.new.data_pack(from: original(folder), version: "1") { |slots| slots.tiles :walls, count: 2 }
      end

      assert_match ":walls", refused.message
      assert_match "fill_from_copy", refused.message
    end
  end

  # A cartridge holds its own data, and nothing hands a cartridge a file as it starts, so a build
  # for a console's cartridge cannot leave its pack out (test/pack_at_start_tests.rb plays the
  # builds for a computer that do).
  def test_a_cartridge_build_cannot_leave_its_pack_out
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc, pack_at_start: true))
      refused = assert_raises(ArgumentError) { made_up_pack(builder, folder) }

      assert_match "cartridge", refused.message
      assert_match "all-in-one", refused.message
    end
  end

  # The build that reads its pack as the game starts (test/pack_at_start_tests.rb plays it), for a
  # computer: built here only, never played, so on every run.
  READS_PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # What the build works out from a picture's pixels is not known for a picture read from the pack as
  # the game starts, so a picture takes colors:, places:, width: and height: from it and nothing else.
  def test_a_picture_read_from_the_pack_as_the_game_starts_is_refused_any_other_option
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) do
        builder.image(:wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0), shading: :fade)
      end

      assert_match ":shading", refused.message
      assert_match "all-in-one", refused.message
    end
  end

  def test_a_picture_read_from_the_pack_must_be_the_size_of_its_tiles
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) do
        builder.image(:wall, width: 16, height: 8, colors: pack[:palette], places: pack[:walls].tile(0))
      end

      assert_match "8x8", refused.message
    end
  end

  def test_places_read_from_the_pack_need_colors
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) { builder.image(:wall, width: 8, height: 8, places: pack[:walls].tile(0)) }

      assert_match "no colors:", refused.message
    end
  end

  def test_tiles_picked_past_the_end_of_a_slot_are_refused
    Dir.mktmpdir do |folder|
      pack = made_up_pack(Builder.new, folder)
      refused = assert_raises(ArgumentError) { pack[:walls].tiles(1, across: 2) }

      assert_match "2 tiles", refused.message
    end
  end

  # An unpacking routine writes a slot of numbers a number at a time, at the slot's width and in its
  # layout's byte order, and reads one back the same way, below zero where the slot is signed. The
  # game reads what it wrote through a table of the slot, which reads the layout as the console does.
  private def numbers_written(folder, width:, signed:, numbers:, platform: :gba)
    from = copy_of(folder, ([0] * 16).pack("C*"), platform: platform)
    count = numbers.length + 1
    b = Builder.new
    b.instance_eval do
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :written, count: count, width: width, signed: signed, layout: platform
        slots.fill_from_copy do |_copy, filled|
          numbers.each_with_index { |number, at| filled[:written][at] = number }
          filled[:written][numbers.length] = filled[:written][1] - 1
        end
      end
      written = table :written, pack[:written]
      reads = Array.new(count) { |at| var(:"read_#{at}", 0) }
      game_loop do
        wait_vblank
        reads.each_with_index { |read, at| read.store!(written[at]) }
      end
    end
    b.finalize_program
    player = game_player.run(b.program, frames: 2)
    Array.new(count) { |at| player[:"read_#{at}"] }
  end

  def test_an_unpacking_writes_a_slot_of_halves_a_number_at_a_time
    Dir.mktmpdir do |folder|
      assert_equal [300, -2, 32_767, -3], numbers_written(folder, width: :half, signed: true, numbers: [300, -2, 32_767])
    end
  end

  def test_an_unpacking_writes_a_genesis_slot_of_halves_high_byte_first
    Dir.mktmpdir do |folder|
      assert_equal [0x1234, 0xFFFF, 0xFFFE],
                   numbers_written(folder, width: :half, signed: false, numbers: [0x1234, 0xFFFF], platform: :genesis)
    end
  end

  def test_an_unpacking_writes_a_slot_of_words_a_number_at_a_time
    Dir.mktmpdir do |folder|
      assert_equal [70_000, -5, -6], numbers_written(folder, width: :word, signed: true, numbers: [70_000, -5])
    end
  end

  def test_an_unpacking_writes_a_genesis_slot_of_words_high_byte_first
    Dir.mktmpdir do |folder|
      assert_equal [0x01020304, 0x00ABCDEF, 0x00ABCDEE],
                   numbers_written(folder, width: :word, signed: false, numbers: [0x01020304, 0x00ABCDEF], platform: :genesis)
    end
  end

  # A number whose place the routine works out as it runs, in a loop, goes to the same place.
  def test_an_unpacking_writes_halves_at_places_it_works_out
    Dir.mktmpdir do |folder|
      from = copy_of(folder, ([0] * 16).pack("C*"))
      b = Builder.new
      b.instance_eval do
        pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :homes, count: 3, width: :half, signed: false
          slots.fill_from_copy { |_copy, filled| repeat(3) { |at| filled[:homes][at] = (at * 1000) + 7 } }
        end
        homes = table :homes, pack[:homes]
        last = var :last, 0
        game_loop do
          wait_vblank
          last.store!(homes[2])
        end
      end
      b.finalize_program

      assert_equal 2007, game_player.run(b.program, frames: 2)[:last]
    end
  end

  # A number written or read past a slot of halves, at a place written in the routine, is refused
  # as the line runs, naming the numbers the slot holds.
  def test_a_number_past_a_slot_of_halves_is_refused
    Dir.mktmpdir do |folder|
      from = copy_of(folder, ([0] * 16).pack("C*"))
      [->(filled) { filled[:homes][3] = 1 }, ->(filled) { filled[:homes][0] = filled[:homes][3] }].each do |line|
        refused = assert_raises(ArgumentError) do
          Builder.new.instance_eval do
            data_pack(from: from, version: "1") do |slots|
              slots.numbers :homes, count: 3, width: :half, signed: false
              slots.fill_from_copy { |_copy, filled| line.call(filled) }
            end
          end
        end

        assert_match "numbers 0 to 2", refused.message
      end
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
