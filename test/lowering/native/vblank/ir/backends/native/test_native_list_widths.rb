# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A LIST KEEPS EACH ITEM IN THE ROOM ITS WIDTH SAYS, in the game as C as on the console: a list of
# bytes costs a byte an item, so a port's pack of hundreds of megabytes, one list of bytes, costs
# its own size in the C that unpacks it and not four times it. A narrow slot still keeps the low
# bits and reads them back as the interpreter does (Reference::ListValue#wrap_to_width); every list
# test on this run holds that, and the end of a run here holds the items as the interpreter does.
class TestNativeListWidths < Minitest::Test
  runs_on_the_main_ractor! # starts the C program it builds

  FinalStateRun = VBlank::IR::Backends::Native::FinalStateRun
  CAPACITY = 1000

  # A list of each width, each with a number its slot keeps the low bits of, and a byte list
  # shifted round its ring, so its items are oldest first from the middle of its memory.
  private def lists_program
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    builder.instance_eval do
      bytes = list :bytes, capacity: CAPACITY, width: :byte, full_of: 0
      halves = list :halves, capacity: CAPACITY, width: :half, full_of: 0
      words = list :words, capacity: CAPACITY, full_of: 0
      ring = list :ring, capacity: 4, width: :byte
      bytes[0] = 200
      bytes[CAPACITY - 1] = -3
      halves[1] = 70_000
      words[2] = -70_000
      ring.push 1
      ring.push 2
      ring.push 3
      ring.shift
      ring.shift
      ring.push 4
      ring.push 5
      ring.push 6
      words[3] = words[2]
      halt
    end
    builder.finalize_program
    builder.program
  end

  private def c_text(program) = VBlank::IR::Backends::Native::Lowering.new(program, title: "VBlank").source_files.values.join

  def test_each_list_is_kept_in_the_c_at_its_width
    text = c_text(lists_program)

    assert_match(/static int8_t \w*bytes\w*\[1000\];/, text)
    assert_match(/static int16_t \w*halves\w*\[1000\];/, text)
    assert_match(/static int32_t \w*words\w*\[1000\];/, text)
  end

  # The game's own reads and writes name the list's width in the C, so a list of whole numbers
  # is read as one with no test of its width on the way: a game's lists cost what they did
  # before narrow lists were kept narrow.
  def test_each_read_and_write_of_a_list_names_its_width_in_the_c
    text = c_text(lists_program)

    assert_match(/rg_list_set_int8\(&\w*bytes\w*,/, text)
    assert_match(/rg_list_set_int16\(&\w*halves\w*,/, text)
    assert_match(/rg_list_set_int32\(&\w*words\w*,/, text)
    assert_match(/rg_list_push_int8\(&\w*ring\w*,/, text)
    assert_match(/rg_list_get_int32\(&\w*words\w*,/, text)
  end

  def test_a_run_to_its_end_holds_each_list_as_the_interpreter_does
    program = lists_program
    wanted = Reference.new.run(program, frames: 2)
    ended = FinalStateRun.new(stuck_after: 30).run(program, frames: 2)

    assert_equal wanted.list(:bytes), ended.lists.fetch(:bytes).unpack("c*")
    assert_equal wanted.list(:ring), ended.lists.fetch(:ring).unpack("c*")
    assert_equal wanted.list(:halves), ended.lists.fetch(:halves)
    assert_equal wanted.list(:words), ended.lists.fetch(:words)
    assert_equal [-56, -3], ended.lists.fetch(:bytes).unpack("c*").values_at(0, CAPACITY - 1)
  end

  # A list written to a file of its own is a byte an item there, after what the file held, and is
  # not in the final state.
  def test_a_list_of_bytes_written_to_its_own_file_is_a_byte_an_item
    Dir.mktmpdir do |folder|
      path = File.join(folder, "bytes.bin")
      File.binwrite(path, "head")
      ended = FinalStateRun.new(stuck_after: 30).run(lists_program, frames: 2,
                                                                    list_file: FinalStateRun::ListFile.new(name: :bytes, path: path))
      written = File.binread(path)

      assert_equal 4 + CAPACITY, written.bytesize
      assert_equal "head", written.byteslice(0, 4)
      assert_equal [-56, -3], written.byteslice(4..).unpack("c*").values_at(0, CAPACITY - 1)
      refute ended.lists.key?(:bytes)
      assert ended.lists.key?(:halves)
    end
  end
end
