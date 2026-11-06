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
#
# The made-up original and the game are MadeUpOriginal's, which test/pack_at_start_tests.rb shares:
# the same game built with its data left out, handed its pack as it starts.
module MadeUpOriginal
  # Sixteen colours: place 0 see-through, then red, green, blue, white and a run of greys.
  PALETTE = [0x0000, 0x001F, 0x03E0, 0x7C00, 0x7FFF, *(1..11).map { |grey| grey * 0x0421 }].freeze
  # Two 8x8 tiles as their places: stripes of three colours, and a diagonal over two greys. Each
  # keeps to three colours, so it fits a Game Boy Color's square of four with black.
  TILE_PLACES = [(0...64).map { |at| 1 + ((at + (at / 8)) % 3) },
                 (0...64).map { |at| (at % 8) == (at / 8) ? 4 : 5 + (at % 2) }].freeze
  SPEEDS = [10, 30, 50, 70, 90, 110, 130, 150].freeze

  # Heights with long runs in them, which the made-up original keeps packed with RLE.
  HEIGHTS = ([3] * 10 + [7, 8] + [1] * 12 + [4, 4, 9]).freeze

  PALETTE_AT = 0x10
  TILES_AT = 0x40
  SPEEDS_AT = 0xA0
  NUDGES_AT = 0xB0
  LZ77_AT = 0x140
  RLE_AT = 0x1A0
  COPY_SIZE = 0x200

  # The tiles as the original keeps them: two pixels a byte, the left one in the low half.
  TILE_BYTES = TILE_PLACES.flatten.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*").freeze

  # The two packed blocks, written by BiosCompress, the packer the Game Boy Advance lowering uses
  # and the answer key for the unpacking: what it packs, the routine unpacks back to these bytes.
  Packer = VBlank::IR::Backends::GBA::BiosCompress
  LZ77_BLOCK = Packer.with_bios_header(Packer.lz77(TILE_BYTES), Packer::TYPE_LZ77, TILE_BYTES.bytesize).freeze
  RLE_BLOCK = Packer.with_bios_header(Packer.rle(HEIGHTS.pack("C*")), Packer::TYPE_RLE, HEIGHTS.length).freeze

  # The made-up original: filler bytes, with the colours, the tiles and the table written where
  # the port's slots say they are, and the same tiles again packed with LZ77, and the heights
  # packed with RLE.
  COPY = begin
    bytes = (0...COPY_SIZE).map { |at| (at * 37 + 11) & 0xFF }.pack("C*")
    bytes[PALETTE_AT, 32] = PALETTE.pack("v*")
    bytes[TILES_AT, TILE_BYTES.bytesize] = TILE_BYTES
    bytes[SPEEDS_AT, SPEEDS.length] = SPEEDS.pack("C*")
    bytes[NUDGES_AT, 2] = [0xF6, 0x0A].pack("C*")
    bytes[LZ77_AT, LZ77_BLOCK.bytesize] = LZ77_BLOCK
    bytes[RLE_AT, RLE_BLOCK.bytesize] = RLE_BLOCK
    bytes.freeze
  end
  SHA1 = Digest::SHA1.hexdigest(COPY)

  # Shareable, as a test class's own constants are made (test_helper.rb), since a test may run in
  # a Ractor and these are a module's.
  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def original(folder)
    path = File.join(folder, "made_up.gba")
    File.binwrite(path, COPY)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path },
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # The game: the two tiles laid out as a background, and a marker whose place across the screen
  # is read from the table each frame. +data+ hands over the colours, each tile's places and the
  # table, from the pack or held directly. +options+ are the build's (Cartridge::Options).
  private def game_program(data, options: VBlank::Cartridge::Options.new)
    b = VBlank::Builder.new(options: options)
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

  # A PORT'S OWN UNPACKING ROUTINE. The tiles and the heights are packed in the made-up original,
  # so their slots say no place in the copy, and the routine fills them: the same routine the
  # build runs on the interpreter, and a player's machine runs as the shell starts.
  private def unpacked_pack(builder, folder)
    builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: 16
      slots.tiles :walls, count: 2
      slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
      slots.fill_from_copy do |copy, pack|
        copy.unpack_lz77 at: LZ77_AT, into: pack[:walls]
        copy.unpack_rle at: RLE_AT, into: pack[:heights]
      end
    end
  end
end

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

  # The unpacking routine (MadeUpOriginal#unpacked_pack), played on each run's own build of it,
  # checked against the interpreter's on every frame there, and its slots read back from what it
  # wrote.
  def test_the_routine_unpacks_an_lz77_block_and_an_rle_block_into_the_same_pack_on_every_run
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(Builder.new, folder).unpacking
      played = game_player.run(unpacking.program, frames: 8)

      assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                   unpacking.slot_bytes_in(played))
    end
  end

  # A shell shows how far the routine has got: the bytes written so far of the pack's whole size.
  def test_the_routine_says_how_far_it_has_got
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(Builder.new, folder).unpacking

      assert_equal 32 + 64 + HEIGHTS.length, unpacking.byte_size
      early = unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the pack is unpacked"
      assert_operator early, :<, unpacking.byte_size, "...and not all of it, since each block waits for a frame"
      assert_equal unpacking.byte_size, unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 8))
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

  # A copy that is +bytes+ alone, written into +folder+.
  private def copy_of(folder, bytes)
    path = File.join(folder, "packed.bin")
    File.binwrite(path, bytes)
    VBlank::Original::Copy.new(path: path, sha1: Digest::SHA1.hexdigest(bytes), release: "Test")
  end

  # One block big enough to take several frames: the count of bytes done moves on inside it, so a
  # shell's progress does not sit at nothing until the whole block is unpacked.
  def test_progress_moves_on_inside_one_big_block
    raw = (0...1024).map { |at| (at * 5) & 0x3F }.pack("C*")
    Dir.mktmpdir do |folder|
      from = copy_of(folder, Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize))
      unpacking = Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :big, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.unpack_lz77 at: 0, into: pack[:big] }
      end.unpacking

      early = unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the block is unpacked"
      assert_operator early, :<, raw.bytesize, "...and not all of it"
      assert_equal raw.bytesize, unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 10))
    end
  end

  # The answer key for the decompressors is BiosCompress: a longer block, with runs and repeats
  # both, packed each way and unpacked by the routine back to its bytes.
  def test_each_decompressor_gives_back_what_bios_compress_packed
    raw = ((0...90).map { |at| (at * 7) & 0x3F } + [0] * 40 + (0...90).map { |at| (at * 7) & 0x3F } + [5] * 3).pack("C*")
    copy = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize) +
           Packer.with_bios_header(Packer.rle(raw), Packer::TYPE_RLE, raw.bytesize)
    rle_at = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize).bytesize
    Dir.mktmpdir do |folder|
      from = copy_of(folder, copy)
      unpacking = Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :by_lz77, count: raw.bytesize, width: :byte, signed: false
        slots.numbers :by_rle, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy do |bytes, pack|
          bytes.unpack_lz77 at: 0, into: pack[:by_lz77]
          bytes.unpack_rle at: rle_at, into: pack[:by_rle]
        end
      end.unpacking

      assert_equal({ by_lz77: raw, by_rle: raw }, unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 8)))
    end
  end

  # A routine can read the copy and write a slot a byte at a time, for a layout no building block
  # knows: here the speeds, read as halves high byte first, kept as their low bytes reversed.
  def test_a_routine_reads_and_writes_bytes_itself
    Dir.mktmpdir do |folder|
      unpacking = Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :backwards, count: 4, width: :byte, signed: false
        slots.fill_from_copy do |copy, pack|
          4.times { |at| pack[:backwards][3 - at] = copy.half(SPEEDS_AT + (at * 2), big_endian: true) & 0xFF }
        end
      end.unpacking

      assert_equal [SPEEDS[1], SPEEDS[3], SPEEDS[5], SPEEDS[7]].reverse.pack("C*"),
                   unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 4))[:backwards]
    end
  end

  # A routine in normal Ruby, as a game block is written: a `while` on a number read from the copy
  # is a loop in the routine, played as it unpacks. The first speed is 10, so it goes round 8 times.
  # `at` is a number the routine changes as it plays, so it is one of the routine's variables.
  def test_a_routine_written_in_normal_ruby_loops_as_it_unpacks
    Dir.mktmpdir do |folder|
      from = original(folder)
      b = Builder.new
      b.instance_eval do
        @made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :doubled, count: 8, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            rounds = copy.byte(SPEEDS_AT) - 2
            while at < rounds
              pack[:doubled][at] = copy.byte(SPEEDS_AT + at) * 2
              at += 1
            end
          end
        end
      end
      unpacking = b.instance_variable_get(:@made_pack).unpacking

      assert_equal SPEEDS.map { |speed| (speed * 2) & 0xFF }.pack("C*"),
                   unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 4))[:doubled]
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

  # What a pack of two tiles filled by +routine+ is refused with, as it is built.
  private def refusal_of_routine(error, &routine)
    Dir.mktmpdir do |folder|
      assert_raises(error) do
        Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.tiles :walls, count: 2
          slots.fill_from_copy(&routine)
        end
      end
    end
  end

  def test_a_block_that_is_not_packed_the_way_the_routine_says_is_refused_at_build_time
    refused = refusal_of_routine(VBlank::Original::WrongCopy) { |copy, pack| copy.unpack_lz77 at: RLE_AT, into: pack[:walls] }

    assert_match "LZ77", refused.message
    assert_match RLE_AT.to_s, refused.message
  end

  # Ten times the first speed is 100, past the 64 bytes of two tiles: a count worked out as the
  # routine runs cannot write into the next slot.
  def test_a_copy_too_long_for_its_slot_is_refused_at_build_time
    refused = refusal_of_routine(ArgumentError) do |copy, pack|
      copy.copy_bytes at: 0, count: copy.byte(SPEEDS_AT) * 10, into: pack[:walls]
    end

    assert_match ":walls", refused.message
    assert_match "bytes 0 to 63", refused.message
  end

  def test_a_byte_written_past_its_slot_is_refused_at_build_time
    refused = refusal_of_routine(ArgumentError) { |copy, pack| pack[:walls][copy.byte(SPEEDS_AT) * 10] = 1 }

    assert_match "byte 100 of slot :walls", refused.message
  end

  # A read past the copy's end, then a write past the slot that it led to: the read is the fault
  # the build names, since it came first.
  def test_a_read_past_the_end_of_the_copy_is_refused_naming_the_place
    refused = refusal_of_routine(VBlank::Original::WrongCopy) do |copy, pack|
      pack[:walls][0] = copy.byte(copy.byte(SPEEDS_AT) * 100)
      pack[:walls][copy.byte(SPEEDS_AT) * 10] = 1
    end

    assert_match "byte 1000", refused.message
    assert_match "0 to #{COPY_SIZE - 1}", refused.message
  end

  # A routine that never ends is stopped after as many frames as the copy and the pack have bytes,
  # not left to run for hours.
  def test_a_routine_that_never_ends_is_stopped
    Dir.mktmpdir do |folder|
      from = original(folder)
      refused = assert_raises(ArgumentError) do
        Builder.new.instance_eval do
          data_pack(from: from, version: "1") do |slots|
            slots.tiles :walls, count: 2
            slots.fill_from_copy do |copy, _pack|
              while copy.byte(0) >= 0
                wait_vblank
              end
            end
          end
        end
      end

      assert_match "did not get to its end", refused.message
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

  # The pixels of a picture read from the pack are not known as the game is built, so nothing can
  # be worked out from them: turning it is refused, as turning a picture the game paints is.
  def test_a_picture_read_from_the_pack_as_the_game_starts_cannot_be_turned
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = made_up_pack(builder, folder)
      builder.image(:wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0))
      refused = assert_raises(ArgumentError) { builder.mirror(:wall) }

      assert_match ":wall", refused.message
      assert_match "data pack as the game starts", refused.message
    end
  end

  # Read from the pack as the game starts, a picture takes both its colours and its places from it.
  def test_a_picture_reading_part_of_itself_from_the_pack_as_the_game_starts_is_refused
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: READS_PACK_AT_START)
      pack = made_up_pack(builder, folder)
      refused = assert_raises(ArgumentError) do
        builder.image(:wall, width: 8, height: 8, colors: pack[:palette], places: TILE_PLACES[0])
      end

      assert_match "both colors: and places:", refused.message
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
