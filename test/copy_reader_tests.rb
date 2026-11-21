# frozen_string_literal: true

require "digest"
require "tmpdir"
require "folder_original"

VBlank.require_game_file "fixtures/record_walk/record_walk_part"
VBlank.require_game_file "fixtures/name_search/name_search_part"
VBlank.require_game_file "plain_ruby_flagged_bytes_part"
VBlank.require_game_file "pair_runs_format"
VBlank.require_game_file "back_copies_format"

# A port's unpacking routine, played (Original::CopyReader, Original::Unpacking): the routine a
# port writes in `slots.fill_from_copy`, built as a program of its own and played by `game_player`.
# It runs in two places only: on the interpreter as a build makes its pack, and in a shell, which
# is a computer program. So these play on the run whose player is the interpreter and on the
# native, JavaScript and Ruby runs, each its own build of the routine checked against the
# interpreter, and never on a console's (test/interpreter/, test/lowering/{native,js,ruby}/, each
# under vblank/original/, include this module). The made-up original is MadeUpOriginal's. A
# format of a port's own, PairRuns, is test/pair_runs_format.rb.

module CopyReaderTests
  include FolderOriginal

  # A copy that is several files: each file read through copy.file, its places counted from that
  # file's start, the places in DATA.MU1 read out of INDEX.MU1 as the routine runs.
  def test_a_routine_reads_each_file_of_a_copy_that_is_several_files
    unpacking = VBlank::Builder.new.data_pack(from: folder_original, version: "1") { |slots| folder_slots(slots) }.unpacking
    played = unpacking.run_on(game_player, frames: 8)

    assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") }, unpacking.slot_bytes_in(played))
  end

  # A read of one file at a place the routine works out as it runs is held to that file, as a place
  # written in the program is: past DATA.MU1's 154 bytes it is a fault naming the file (1, the
  # release's second) and the first byte read outside it, counted from the file's start, and not a
  # read of whatever file comes next. The answer key is the release's file sizes (FolderOriginal).
  # The build leaves its pack out, so the routine is played here and not first by the build.
  PACK_LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
  DATA_FILE_NUMBER = 1

  private def fault_reading_data_file(count: 4, formats: [], &read)
    b = VBlank::Builder.new(options: PACK_LEFT_OUT)
    b.data_pack(from: folder_original(nil), version: "1", formats: formats) do |slots|
      slots.numbers :read, count: count, width: :byte, signed: false
      slots.fill_from_copy do |copy, pack, release|
        read.call(copy.file("INDEX.#{release}"), copy.file("DATA.#{release}"), pack[:read])
      end
    end
    unpacking = b.declared_data_pack.unpacking(release: VBlank::Original::Release.from("MU1", RELEASES.fetch("MU1")))
    played = game_player.hand_file(folder_original.copy.read_bytes).run(unpacking.program, frames: 8)
    unpacking.fault_in(played)
  end

  private def assert_read_outside_data_file(first_outside, fault)
    refute_nil fault, "the read outside DATA.MU1 is a fault"
    assert_equal [VBlank::Original::Unpacking::Fault::READ_OUTSIDE_FILE, first_outside, DATA_FILE_NUMBER],
                 [fault.kind, fault.at, fault.detail]
  end

  def test_a_run_time_place_past_the_end_of_a_file_is_a_fault_naming_the_file
    # The colours start at 16 in DATA.MU1, so this is byte 216 of a file of 154.
    fault = fault_reading_data_file { |index, data, slot| data.copy_bytes at: index.word(6) + 200, count: 4, into: slot }

    assert_read_outside_data_file 216, fault
  end

  def test_a_run_time_copy_that_starts_inside_a_file_and_runs_past_its_end_is_a_fault_at_the_end
    # The heights start at 120, and 40 bytes from there run past byte 153.
    fault = fault_reading_data_file(count: 40) { |index, data, slot| data.copy_bytes at: index.word(14), count: 40, into: slot }

    assert_read_outside_data_file 154, fault
  end

  def test_a_fixed_place_with_a_run_time_count_past_the_end_of_a_file_is_a_fault_at_the_end
    # INDEX.MU1 starts "MUIX": its first byte is 77, so 77 bytes from byte 150.
    fault = fault_reading_data_file(count: 80) { |index, data, slot| data.copy_bytes at: 150, count: index.byte(0), into: slot }

    assert_read_outside_data_file 154, fault
  end

  def test_a_run_time_byte_and_word_past_the_end_of_a_file_are_faults
    byte = fault_reading_data_file { |index, data, slot| slot[0] = data.byte(index.word(6) + 200) }
    word = fault_reading_data_file { |index, data, slot| slot[0] = data.word(index.word(6) + 136) }

    assert_read_outside_data_file 216, byte
    # The word is bytes 152 to 155.
    assert_read_outside_data_file 154, word
  end

  def test_a_format_unpacking_from_a_run_time_place_past_the_end_of_a_file_is_a_fault
    fault = fault_reading_data_file(formats: [PairRuns]) do |index, data, slot|
      data.unpack_pair_runs at: index.word(6) + 150, into: slot
    end

    assert_read_outside_data_file 166, fault
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

  # A format's routine in normal Ruby (test/back_copies_format.rb): seven counters, each a local set
  # with `=` and moved on with `+=` in loops inside loops and on both sides of the routine's tests,
  # one set from the copy's bytes before the place it read them moves on. It unpacks what the Ruby
  # answer key does, and so does the same format with each counter a `block.variable`.
  private def back_copies_unpacked(folder, format)
    from = copy_of(folder, ([0xAA] + BackCopies::PACKED + [0xAA]).pack("C*"))
    size = BackCopies.unpacked(BackCopies::PACKED, BackCopies::TAG).length
    unpacking = VBlank::Builder.new.data_pack(from: from, version: "1", formats: [format]) do |slots|
      slots.numbers :out, count: size, width: :byte, signed: false
      slots.fill_from_copy do |copy, pack|
        case format.format_name
        when :back_copies then copy.unpack_back_copies at: 1, into: pack[:out], tag: BackCopies::TAG
        else copy.unpack_back_copies_by_variables at: 1, into: pack[:out], tag: BackCopies::TAG
        end
      end
    end.unpacking
    played = unpacking.run_on(game_player, frames: 4)
    assert_nil unpacking.fault_in(played)
    [unpacking.slot_bytes_in(played)[:out], unpacking.bytes_done_in(played)]
  end

  def test_a_formats_routine_in_normal_ruby_keeps_its_counters
    wanted = BackCopies.unpacked(BackCopies::PACKED, BackCopies::TAG).pack("C*")
    Dir.mktmpdir do |folder|
      assert_equal [wanted, wanted.bytesize], back_copies_unpacked(folder, BackCopiesFormat), "in normal Ruby"
      assert_equal [wanted, wanted.bytesize], back_copies_unpacked(folder, BackCopiesByVariablesFormat), "with block.variable"
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

  # A pack bigger than a cartridge's work memory unpacks on each run that plays this file, as every
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

  # Steps asked for from a Ruby loop, each at places written in the program, are rows of a table
  # that one loop of the routine reads (CopyReader#fold_constant_steps!), not a copy of the step
  # each: the routine is the same size for forty steps as for four. A step at a place the routine
  # works out as it runs is written as it is, and ends a run of rows. Each step still waits a
  # frame after its block, so the routine ends on the same frame: SCATTERED_BYTES copies, the one
  # placed by a read, then RLE_COPIES blocks of heights, a frame each.
  SCATTERED_BYTES = 40
  RLE_COPIES = 6
  STEPS_FROM_LOOPS = SCATTERED_BYTES + 1 + RLE_COPIES

  private def steps_from_loops(folder)
    VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
      slots.numbers :scattered, count: SCATTERED_BYTES, width: :byte, signed: false
      slots.numbers :pointed, count: 1, width: :byte, signed: false
      slots.numbers :heights, count: HEIGHTS.length * RLE_COPIES, width: :byte, signed: false
      slots.fill_from_copy do |copy, pack|
        SCATTERED_BYTES.times { |n| copy.copy_bytes at: (n * 13) % COPY_SIZE, count: 1, into: pack[:scattered], start: n }
        copy.copy_bytes at: copy.byte(SPEEDS_AT), count: 1, into: pack[:pointed]
        RLE_COPIES.times { |n| copy.unpack_rle at: RLE_AT, into: pack[:heights], start: n * HEIGHTS.length }
      end
    end.unpacking
  end

  # How many calls the routine makes of the block routine named +part+.
  private def block_calls(program, part)
    target = VBlank::Messages::MadeNames.make(:unpacking_part, part: part)
    program.walk.count { |node| node.kind == :call && node.target == target }
  end

  def test_steps_asked_for_from_a_loop_unpack_as_written_out_from_one_loop_of_the_routine
    Dir.mktmpdir do |folder|
      unpacking = steps_from_loops(folder)
      played = unpacking.run_on(game_player, frames: STEPS_FROM_LOOPS)
      one_frame_short = unpacking.run_on(game_player, frames: STEPS_FROM_LOOPS - 1)

      assert_equal({ scattered: Array.new(SCATTERED_BYTES) { |n| COPY.getbyte((n * 13) % COPY_SIZE) }.pack("C*"),
                     pointed: COPY.byteslice(COPY.getbyte(SPEEDS_AT), 1), heights: (HEIGHTS * RLE_COPIES).pack("C*") },
                   unpacking.slot_bytes_in(played))
      assert unpacking.finished_in?(played), "a frame for each step, and the routine ends"
      refute unpacking.finished_in?(one_frame_short), "...and not a frame sooner"
      # The forty copies are one call in a loop, the copy placed by a read one more; the six blocks of
      # heights one call in a loop.
      assert_equal [2, 1], [block_calls(unpacking.program, :copy), block_calls(unpacking.program, :unpack_rle)]
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

  # Reads placed by the answers of reads: a byte, a half high byte first and a word, each at the
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

  # A loop whose test reads the copy at a place the loop moves on reads the new place each time
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
  POINTED_COPY = VBlank::Testing::InRactors.shareable(((8...16).to_a + [7, 6, 5, 4, 3, 0, 2, 1]).pack("C*"))

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

  # A loop bounded by a count and by a marker of the copy, joined with `&&`, stops at whichever
  # comes first, as Ruby's does: pieces of four bytes, a piece whose first byte is 0x80 ending each
  # frame. The second frame is longer than the bound, so the bound stops it.
  PIECE_BYTES = 4
  MOST_PIECES = 5
  PIECES_END = 0x80
  PIECES_IN_EACH_FRAME = VBlank::Testing::InRactors.shareable([3, 7, 1])
  ORDINARY_PIECE_BYTES = VBlank::Testing::InRactors.shareable([1, 2, 3, 4])
  FRAME_END_PIECE_BYTES = VBlank::Testing::InRactors.shareable([PIECES_END, 0, 0, 0])

  private def piece_copy
    PIECES_IN_EACH_FRAME.flat_map { |pieces| (ORDINARY_PIECE_BYTES * pieces) + FRAME_END_PIECE_BYTES }.pack("C*")
  end

  # Where each frame starts in the copy: after the pieces of those before it and their end pieces.
  private def frame_starts = PIECES_IN_EACH_FRAME.each_with_index.map { |_, frame| PIECES_IN_EACH_FRAME.take(frame).sum { |pieces| (pieces + 1) * PIECE_BYTES } }

  private def pieces_counted(copy)
    frame_starts.map do |at|
      count = 0
      count += 1 while count < MOST_PIECES && copy.getbyte(at + (count * PIECE_BYTES)) != PIECES_END
      count
    end
  end

  def test_a_loop_bounded_by_a_count_and_a_marker_of_the_copy_stops_at_either
    Dir.mktmpdir do |folder|
      from = copy_of(folder, piece_copy)
      starts = frame_starts
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :counts, count: PIECES_IN_EACH_FRAME.length, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            starts.each_with_index do |at, frame|
              count = 0
              count += 1 while count < MOST_PIECES && copy.byte(at + (count * PIECE_BYTES)) != PIECES_END
              pack[:counts][frame] = count
            end
          end
        end
      end
      unpacking = made_pack.unpacking
      played = unpacking.run_on(game_player, frames: 4)

      assert unpacking.finished_in?(played), "the unpacking got to its end"
      assert_equal({ counts: pieces_counted(piece_copy).pack("C*") }, unpacking.slot_bytes_in(played))
    end
  end

  # A loop's test is checked against the copy's end on every round, as a read in its body is: a
  # copy with no 0 is read past its end on the seventh round, and the build says which byte. A
  # read past the end does not stop the routine, so the loop has a bound of its own to end on.
  def test_a_loop_whose_test_reads_past_the_copys_end_is_refused_naming_that_byte
    Dir.mktmpdir do |folder|
      from = copy_of(folder, [9, 8, 7, 6, 5, 4].pack("C*"))
      b = VBlank::Builder.new
      refused = assert_raises(VBlank::Original::WrongCopy) do
        b.instance_eval do
          data_pack(from: from, version: "1") do |slots|
            slots.numbers :until_nought, count: 1, width: :byte, signed: false
            slots.fill_from_copy do |copy, pack|
              at = 0
              at += 1 while at < 10 && copy.byte(at) != 0
              pack[:until_nought][0] = at
            end
          end
        end
      end

      assert_match "byte 6 ", refused.message
    end
  end

  # A loop's test read past the copy's end on a later round stops the routine there with the plain
  # refusal, on every run's build of it. The copy holds two bytes and no 0, so the third round
  # reads byte 2: in `stop_when:`, and in a `while` with no bound of its own, which a read past
  # the end must end. The answer key is the copy's length.
  NO_NOUGHT_COPY = VBlank::Testing::InRactors.shareable([9, 8].pack("C*"))

  # The error the unpacking +b+ declared (with the pack left out) stops with, played on the run's
  # player handed NO_NOUGHT_COPY.
  private def refusal_reading_no_nought_copy(b)
    release = VBlank::Original::Release.from("Test", { "sha1" => Digest::SHA1.hexdigest(NO_NOUGHT_COPY),
                                                       "size" => NO_NOUGHT_COPY.bytesize })
    unpacking = b.declared_data_pack.unpacking(release: release)
    played = game_player.hand_file(NO_NOUGHT_COPY).run(unpacking.program, frames: 8)
    refute unpacking.finished_in?(played), "the read past the end stops the routine"
    fault = unpacking.fault_in(played)
    refute_nil fault, "the read past the end is a fault"
    unpacking.fault_error(fault)
  end

  def test_a_stop_when_that_reads_past_the_copys_end_on_a_later_round_stops_the_routine_there
    Dir.mktmpdir do |folder|
      from = copy_of(folder, NO_NOUGHT_COPY)
      b = VBlank::Builder.new(options: PACK_LEFT_OUT)
      b.instance_eval do
        data_pack(from: from, version: "1") do |slots|
          slots.numbers :reached, count: 1, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = var(:at, 0)
            repeat(10, stop_when: copy.byte(at) == 0) { at.increase!(1) }
            pack[:reached][0] = at
          end
        end
      end
      refused = refusal_reading_no_nought_copy(b)

      assert_kind_of VBlank::Original::WrongCopy, refused
      assert_match "reads byte 2 ", refused.message
    end
  end

  def test_a_while_with_no_bound_that_reads_past_the_copys_end_stops_the_routine_there
    Dir.mktmpdir do |folder|
      from = copy_of(folder, NO_NOUGHT_COPY)
      b = VBlank::Builder.new(options: PACK_LEFT_OUT)
      b.instance_eval do
        data_pack(from: from, version: "1") do |slots|
          slots.numbers :reached, count: 1, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            at += 1 while copy.byte(at) != 0
            pack[:reached][0] = at
          end
        end
      end
      refused = refusal_reading_no_nought_copy(b)

      assert_kind_of VBlank::Original::WrongCopy, refused
      assert_match "reads byte 2 ", refused.message
    end
  end

  # A list walked until a record says it is the last, as an original walks a group of pictures:
  # records of four words (where from, where to, how many, another follows), two of them here.
  RECORDS_AT = 100
  RECORDS = VBlank::Testing::InRactors.shareable([[1000, 0, 300, 1], [2000, 600, 200, 0]])

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

  # An archive searched for one file by its name, as an original keeps its pictures and levels:
  # NameSearchPart (test/fixtures/name_search) says the layout. The file looked for is the third,
  # after one whose name differs in every letter and one that differs in a single letter, so a
  # count of differing letters that is not set back to 0 each round never finds it. The archive
  # ends with the header of a file longer than what is left, which ends every search: one that
  # never finds the name answers 0, and the bytes copied from there are the wrong ones, where a
  # search walking on would read past the end of the copy.
  ARCHIVE_FILES = VBlank::Testing::InRactors.shareable([["wall", "bricks"], ["dour", "no"], ["door", "hinges!"], ["ship", "sail"]])
  ARCHIVE_END = ("tail".b + [0xFFFF].pack("V")).freeze
  ARCHIVE = ("MU1".b + ARCHIVE_FILES.map { |name, held| name.b + [held.bytesize].pack("V") + held.b }.join + ARCHIVE_END).freeze
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

  # A routine written in a game file (test/plain_ruby_flagged_bytes_part.rb) sets `flags` and
  # `byte` from the slot it reads, then moves `at` on before it uses them: each holds the byte read
  # before the move, in the routine's own lines and in a method of the file it calls. The answer
  # is FlaggedBytes.unpacked, in Ruby.
  def test_a_name_set_from_a_byte_a_game_files_routine_reads_holds_that_byte
    Dir.mktmpdir do |folder|
      from = copy_of(folder, FlaggedBytes::PACKED.pack("C*"))
      wanted = FlaggedBytes.unpacked(FlaggedBytes::PACKED).pack("C*")
      [false, true].each do |by_method|
        unpacking = flagged_bytes_pack(VBlank::Builder.new, from, by_method: by_method).unpacking
        played = unpacking.run_on(game_player, frames: 4)

        assert_equal wanted, unpacking.slot_bytes_in(played)[:unpacked], by_method ? "in a method" : "in the routine's lines"
      end
    end
  end

  # A reader written in a game file (FlaggedByteReader, test/plain_ruby_flagged_bytes_part.rb)
  # sets `at` from a place kept in a list, moves the place on, then reads the copy at `at`; and sets
  # `high` from one such read before the next. Each holds what it was set to: the first byte, 5,
  # then 10 and 20 joined. Read late, `at` would be the moved place and `high` the byte after.
  def test_a_name_set_from_a_place_a_readers_method_moves_on_holds_the_place_before
    Dir.mktmpdir do |folder|
      from = copy_of(folder, FlaggedBytes::PACKED.pack("C*"))
      unpacking = flagged_byte_reader_pack(VBlank::Builder.new, from).unpacking
      played = unpacking.run_on(game_player, frames: 4)

      first, second, third = FlaggedBytes::PACKED
      assert_equal [first, (second << 8) | third].pack("v*"), unpacking.slot_bytes_in(played)[:read]
    end
  end

  # A made-up format no building block knows, decoded by the game's own code as a port writes it:
  # pairs of a count and a byte, the byte written that many times, until a count of 0. The
  # decoder says what it wrote with `count_written`, so the count of bytes done moves on, and the
  # routine waits for the next frame as the building blocks do.
  OWN_FORMAT_RUNS = VBlank::Testing::InRactors.shareable([[200, 7], [150, 9], [255, 3], [255, 1], [140, 4]])
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
