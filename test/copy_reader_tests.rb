# frozen_string_literal: true

require "digest"
require "tmpdir"
require "folder_original"

VBlank.require_game_file "fixtures/record_walk/record_walk_part"
VBlank.require_game_file "fixtures/name_search/name_search_part"

# A PORT'S UNPACKING ROUTINE, PLAYED (Original::CopyReader, Original::Unpacking): the routine a
# port writes in `slots.fill_from_copy`, built as a program of its own and played by `game_player`.
# It runs in two places only: on the interpreter as a build makes its pack, and in a shell, which
# is a computer program. So these play on the run whose player is the interpreter and on the
# native, JavaScript and Ruby runs, each its own build of the routine checked against the
# interpreter, and never on a console's (test/interpreter/, test/lowering/{native,js,ruby}/, each
# under vblank/original/, include this module). The made-up original is MadeUpOriginal's.

# A MADE-UP PACKED FORMAT, written as a port writes one of its own (Original::Packing::Format):
# pairs of a count and a byte, the byte written that many times, each count multiplied by the
# `times:` setting, until a count of 0.
module PairRuns
  extend VBlank::Original::Packing::Format
  unpacks :pair_runs, times: 1

  # The most pairs a block can hold, a bound on the loop that reads them.
  MOST_PAIRS = 4096

  def self.routine(block)
    at = block.variable(:at)
    many = block.variable(:many)
    at.store!(block.from)
    many.store!(block.byte(at))
    block.repeat(MOST_PAIRS, stop_when: (many == 0) | block.finished) do
      block.repeat(many * block.setting(:times), stop_when: block.finished) { block.write(block.byte(at + 1)) }
      at.increase!(2)
      many.store!(block.byte(at))
    end
  end
end

module CopyReaderTests
  include FolderOriginal

  # A copy that is several files: each file read through copy.file, its places counted from that
  # file's start, the places in DATA.MU1 read out of INDEX.MU1 as the routine runs.
  def test_a_routine_reads_each_file_of_a_copy_that_is_several_files
    unpacking = VBlank::Builder.new.data_pack(from: folder_original, version: "1") { |slots| folder_slots(slots) }.unpacking
    played = unpacking.run_on(game_player, frames: 8)

    assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") }, unpacking.slot_bytes_in(played))
  end

  # The port's format, named in `formats:`, gives the copy `unpack_pair_runs`, with its setting.
  def test_a_format_of_the_ports_own_unpacks_and_counts_what_it_writes
    Dir.mktmpdir do |folder|
      from = copy_of(folder, [0xEE, 3, 7, 2, 9, 0, 0xEE].pack("C*"))
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1", formats: [PairRuns]) do |slots|
        slots.numbers :runs, count: 10, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.unpack_pair_runs at: 1, into: pack[:runs], times: 2 }
      end.unpacking
      played = unpacking.run_on(game_player, frames: 4)

      assert_equal({ runs: ([7] * 6 + [9] * 4).pack("C*") }, unpacking.slot_bytes_in(played))
      assert_equal 10, unpacking.bytes_done_in(played)
    end
  end

  # A shell shows how far the routine has got: the bytes written so far of the pack's whole size.
  def test_the_routine_says_how_far_it_has_got
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(VBlank::Builder.new, folder).unpacking

      assert_equal 32 + 64 + HEIGHTS.length, unpacking.byte_size
      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the pack is unpacked"
      assert_operator early, :<, unpacking.byte_size, "...and not all of it, since each block waits for a frame"
      assert_equal unpacking.byte_size, unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 8))
    end
  end

  # One block big enough to take several frames: the count of bytes done moves on inside it, so a
  # shell's progress does not sit at nothing until the whole block is unpacked.
  def test_progress_moves_on_inside_one_big_block
    raw = (0...1024).map { |at| (at * 5) & 0x3F }.pack("C*")
    Dir.mktmpdir do |folder|
      from = copy_of(folder, Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize))
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :big, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.unpack_lz77 at: 0, into: pack[:big] }
      end.unpacking

      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the block is unpacked"
      assert_operator early, :<, raw.bytesize, "...and not all of it"
      assert_equal raw.bytesize, unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 10))
    end
  end

  # A PACK BIGGER THAN A CARTRIDGE'S WORK MEMORY UNPACKS on each run that plays this file, as every
  # console, the Color's 8 KB among them. An unpacking runs only on a computer, in a shell, so no
  # build holds it to the console's memory, and a run's player does not either (Testing::BuildChecks).
  def test_a_pack_bigger_than_a_cartridges_work_memory_unpacks
    raw = (0...(10 * 1024)).map { |at| (at * 7) & 0xFF }.pack("C*")
    Dir.mktmpdir do |folder|
      unpacking = VBlank::Builder.new.data_pack(from: copy_of(folder, raw), version: "1") do |slots|
        slots.numbers :big, at: 0, count: raw.bytesize, width: :byte, signed: false
      end.unpacking
      played = unpacking.run_on(game_player, frames: 80)

      assert unpacking.finished_in?(played), "the unpacking got to its end"
      assert_equal raw, unpacking.slot_bytes_in(played)[:big]
    end
  end

  # A routine can read the copy and write a slot a byte at a time, for a layout no building block
  # knows: here the speeds, read as halves high byte first, kept as their low bytes reversed.
  def test_a_routine_reads_and_writes_bytes_itself
    Dir.mktmpdir do |folder|
      unpacking = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :backwards, count: 4, width: :byte, signed: false
        slots.fill_from_copy do |copy, pack|
          4.times { |at| pack[:backwards][3 - at] = copy.half(SPEEDS_AT + (at * 2), big_endian: true) & 0xFF }
        end
      end.unpacking

      assert_equal [SPEEDS[1], SPEEDS[3], SPEEDS[5], SPEEDS[7]].reverse.pack("C*"),
                   unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4))[:backwards]
    end
  end

  # A routine in normal Ruby, as a game block is written: a `while` on a number read from the copy
  # is a loop in the routine, played as it unpacks. The first speed is 10, so it goes round 8 times.
  # `at` is a number the routine changes as it plays, so it is one of the routine's variables.
  def test_a_routine_written_in_normal_ruby_loops_as_it_unpacks
    Dir.mktmpdir do |folder|
      from = original(folder)
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
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
      unpacking = made_pack.unpacking

      assert_equal SPEEDS.map { |speed| (speed * 2) & 0xFF }.pack("C*"),
                   unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4))[:doubled]
    end
  end

  # READS PLACED BY THE ANSWERS OF READS: a byte, a half high byte first and a word, each at the
  # place the read before it gave, round after round. Each such place is kept where its read is
  # written (BlockKitInternals#emit_held_place), and what is read is what Ruby reads from the copy.
  CHAINED_ROUNDS = 6

  private def chained_copy = (0...512).map { |at| ((at * 37) + 11) & 0xFF }.pack("C*")

  private def chained_answers(copy)
    at = copy.getbyte(5)
    Array.new(CHAINED_ROUNDS) do
      at = copy.byteslice(at, 4).unpack1("V") & 0xFF
      at = copy.byteslice(at, 2).unpack1("n") & 0xFF
      at = copy.getbyte(at)
    end
  end

  def test_reads_placed_by_the_answers_of_reads_read_what_the_copy_holds
    Dir.mktmpdir do |folder|
      rounds = CHAINED_ROUNDS
      unpacking = VBlank::Builder.new.data_pack(from: copy_of(folder, chained_copy), version: "1") do |slots|
        slots.numbers :read, count: rounds, width: :byte, signed: false
        slots.fill_from_copy do |copy, pack|
          at = copy.byte(5)
          rounds.times do |round|
            at = copy.word(at) & 0xFF
            at = copy.half(at, big_endian: true) & 0xFF
            at = copy.byte(at)
            pack[:read][round] = at
          end
        end
      end.unpacking
      played = unpacking.run_on(game_player, frames: 4)

      assert_nil unpacking.fault_in(played)
      assert_equal({ read: chained_answers(chained_copy).pack("C*") }, unpacking.slot_bytes_in(played))
    end
  end

  # A LOOP WHOSE TEST READS THE COPY at a place the loop moves on reads the new place each time
  # round: a place the routine keeps in a variable is read where the answer is used, not held.
  def test_a_loop_whose_test_reads_the_copy_reads_each_new_place
    Dir.mktmpdir do |folder|
      from = copy_of(folder, [9, 8, 7, 6, 0, 5].pack("C*"))
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :until_nought, count: 1, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            at += 1 while copy.byte(at) != 0
            pack[:until_nought][0] = at
          end
        end
      end
      unpacking = made_pack.unpacking

      assert_equal({ until_nought: [4].pack("C*") }, unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4)))
    end
  end

  # ...and so does one whose test reads the copy at a place another read gives: the place is read
  # again each time round, in a `while` and in `stop_when:` alike. Bytes 0 to 7 are places of bytes
  # 8 to 15, and the byte at the place byte 5 gives is the first that is 0.
  POINTED_COPY = Ractor.make_shareable(((8...16).to_a + [7, 6, 5, 4, 3, 0, 2, 1]).pack("C*"))

  private def first_pointing_at_nought(copy) = (0..).find { |at| copy.getbyte(copy.getbyte(at)).zero? }

  # The first place whose byte, read three deep, is 13; and the first whose byte read two deep is
  # not 7.
  private def first_three_deep_at_thirteen(copy) = (0..).find { |at| copy.getbyte(copy.getbyte(copy.getbyte(at))) == 13 }
  private def first_two_deep_not_seven(copy) = (0..).find { |at| copy.getbyte(copy.getbyte(at)) != 7 }

  def test_a_loop_whose_test_reads_the_copy_at_a_place_another_read_gives_reads_each_new_place
    Dir.mktmpdir do |folder|
      from = copy_of(folder, POINTED_COPY)
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :by_while, count: 1, width: :byte, signed: false
          slots.numbers :by_stop_when, count: 1, width: :byte, signed: false
          slots.numbers :three_deep, count: 1, width: :byte, signed: false
          slots.numbers :by_stop_value, count: 1, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            at += 1 while copy.byte(copy.byte(at)) != 0
            pack[:by_while][0] = at
            walked = var(:walked, 0)
            repeat(15, stop_when: copy.byte(copy.byte(walked)) == 0) { walked.increase!(1) }
            pack[:by_stop_when][0] = walked
            deep = 0
            deep += 1 while copy.byte(copy.byte(copy.byte(deep))) != 13
            pack[:three_deep][0] = deep
            stepped = var(:stepped, 0)
            repeat(15, stop_when: copy.byte(copy.byte(stepped)) ^ 7) { stepped.increase!(1) }
            pack[:by_stop_value][0] = stepped
          end
        end
      end
      unpacking = made_pack.unpacking
      first = [first_pointing_at_nought(POINTED_COPY)].pack("C*")

      assert_equal({ by_while: first, by_stop_when: first, three_deep: [first_three_deep_at_thirteen(POINTED_COPY)].pack("C*"),
                     by_stop_value: [first_two_deep_not_seven(POINTED_COPY)].pack("C*") },
                   unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4)))
    end
  end

  # A LIST WALKED UNTIL A RECORD SAYS IT IS THE LAST, as an original walks a group of pictures:
  # records of four words (where from, where to, how many, another follows), two of them here.
  RECORDS_AT = 100
  RECORDS = Ractor.make_shareable([[1000, 0, 300, 1], [2000, 600, 200, 0]])

  private def record_copy
    bytes = (0...4096).map { |at| (at * 7) & 0xFF }.pack("C*")
    bytes[RECORDS_AT, 32] = RECORDS.flatten.pack("V*")
    bytes
  end

  # What the two records copy into a slot of 1024 bytes, the rest zero.
  private def records_copied(copy)
    out = "\0".b * 1024
    RECORDS.each { |from, to, count, _| out[to, count] = copy.byteslice(from, count) }
    out
  end

  # +walk+ is a method of RecordWalkPart (test/fixtures/record_walk), a part in a game file.
  private def walked_records(folder, copy, walk)
    from = copy_of(folder, copy)
    unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
      slots.pixels :out, count: 1024
      slots.fill_from_copy do |reader, pack|
        part = RecordWalkPart.new(reader, pack)
        walk == :flag ? part.fill_with_flag(RECORDS_AT) : part.fill(RECORDS_AT)
      end
    end.unpacking
    unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 8))[:out]
  end

  # The loop's test reads a name its body sets from the copy, so the loop is the game's, and the
  # names it changes are the game's to keep, in a part's method as in a game block.
  def test_a_routine_walks_records_until_one_says_it_is_the_last
    Dir.mktmpdir do |folder|
      copy = record_copy

      assert_equal records_copied(copy), walked_records(folder, copy, :number), "kept as the number read"
      assert_equal records_copied(copy), walked_records(folder, copy, :flag), "kept as true or false"
    end
  end

  # AN ARCHIVE SEARCHED FOR ONE FILE BY ITS NAME, as an original keeps its pictures and levels:
  # NameSearchPart (test/fixtures/name_search) says the layout. The file looked for is the third,
  # after one whose name differs in every letter and one that differs in a single letter, so a
  # count of differing letters that is not set back to 0 each round never finds it.
  ARCHIVE_FILES = Ractor.make_shareable([["wall", "bricks"], ["dour", "no"], ["door", "hinges!"], ["ship", "sail"]])
  ARCHIVE = ("MU1".b + ARCHIVE_FILES.map { |name, held| name.b + [held.bytesize].pack("V") + held.b }.join + ("\0".b * 8)).freeze
  ARCHIVE_NAME = "door"

  # The slot a routine fills from where +search+ says the named file starts. +search+ is called on
  # the routine's builder with a NameSearchPart, the copy and a table of the name's letters.
  private def bytes_found_in_archive(folder, &search)
    from = copy_of(folder, ARCHIVE)
    held = ARCHIVE_FILES.to_h.fetch(ARCHIVE_NAME).bytesize
    b = VBlank::Builder.new
    made_pack = nil
    b.instance_eval do
      made_pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :found, count: held, width: :byte, signed: false
        slots.fill_from_copy do |copy, pack|
          letters = table :archive_name, ARCHIVE_NAME.bytes, width: :byte
          part = NameSearchPart.new(self, copy, ARCHIVE.bytesize)
          copy.copy_bytes at: instance_exec(part, copy, letters, &search), count: held, into: pack[:found]
        end
      end
    end
    unpacking = made_pack.unpacking
    unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 8))[:found]
  end

  private def assert_archive_file_found(why = nil, &search)
    Dir.mktmpdir { |folder| assert_equal ARCHIVE_FILES.to_h.fetch(ARCHIVE_NAME), bytes_found_in_archive(folder, &search), why }
  end

  # `differing = 0` at the top of a `while` in a part's method, changed in a `@build.repeat` block:
  # the line sets it on every round, as it does written in the routine's own block.
  def test_a_count_set_at_the_top_of_a_loop_in_a_parts_method_starts_afresh_each_round
    assert_archive_file_found("while") { |part, _copy, letters| part.start_counted_by_repeat(letters) }
    assert_archive_file_found("until") { |part, _copy, letters| part.start_counted_in_until(letters) }
    assert_archive_file_found("a while inside") { |part, _copy, letters| part.start_counted_by_inner_while(letters) }
    assert_archive_file_found("a Ruby list") { |part, _copy, _letters| part.start_counted_over_ruby_list(ARCHIVE_NAME.bytes) }
  end

  def test_a_count_set_at_the_top_of_a_loop_in_a_game_files_method_starts_afresh_each_round
    assert_archive_file_found { |_part, copy, letters| name_search_start(self, copy, ARCHIVE.bytesize, letters) }
  end

  # The names the loop's test reads are plain numbers when the loop is reached, and the body
  # changes them only under a test the routine makes: they are the routine's to keep from there.
  def test_a_loop_whose_names_change_only_under_a_test_of_the_routines_is_the_routines_loop
    assert_archive_file_found { |part, _copy, letters| part.start_moved_on_in_else(letters) }
  end

  # A MADE-UP FORMAT NO BUILDING BLOCK KNOWS, decoded by the game's own code as a port writes it:
  # pairs of a count and a byte, the byte written that many times, until a count of 0. The
  # decoder says what it wrote with `count_written`, so the count of bytes done moves on, and the
  # routine waits for the next frame as the building blocks do.
  OWN_FORMAT_RUNS = Ractor.make_shareable([[200, 7], [150, 9], [255, 3], [255, 1], [140, 4]])
  OWN_FORMAT_BYTES = OWN_FORMAT_RUNS.flat_map { |many, byte| [byte] * many }.pack("C*").freeze

  def test_count_written_moves_progress_on_in_a_decoder_of_the_games_own
    Dir.mktmpdir do |folder|
      from = copy_of(folder, (OWN_FORMAT_RUNS.flatten + [0, 0]).pack("C*"))
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :runs, count: OWN_FORMAT_BYTES.bytesize, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            out = 0
            many = copy.byte(at)
            while many > 0
              repeat(many) do
                pack[:runs][out] = copy.byte(at + 1)
                out += 1
              end
              copy.count_written many
              at += 2
              many = copy.byte(at)
            end
          end
        end
      end
      unpacking = made_pack.unpacking

      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the runs are counted"
      assert_operator early, :<, OWN_FORMAT_BYTES.bytesize, "...and not all of them, since the routine waits for a frame"
      played = unpacking.run_on(game_player, frames: 20)
      assert_equal({ runs: OWN_FORMAT_BYTES }, unpacking.slot_bytes_in(played))
      assert_equal OWN_FORMAT_BYTES.bytesize, unpacking.bytes_done_in(played)
    end
  end
end
