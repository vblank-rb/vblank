# frozen_string_literal: true

require "test_helper"

# A LIST KEEPS EACH ITEM IN THE ROOM ITS WIDTH SAYS in the web build, as in the game as C: a list
# of bytes is an Int8Array, a byte an item, so a port's pack of hundreds of megabytes, one list of
# bytes, costs its own size in the browser that unpacks it and not four times it. A narrow slot
# still keeps the low bits and reads them back as the interpreter does
# (Reference::ListValue#wrap_to_width); every list test on this run holds that too.
#
# The lists are made and read through runtime/rg_list.js in one run of node (list_harness.js).
class TestJSListWidths < Minitest::Test
  JS = VBlank::IR::Backends::JS
  HARNESS = Ractor.make_shareable(File.expand_path("list_harness.js", __dir__))
  RUNTIME = Ractor.make_shareable(%w[rg_int32.js rg_list.js].map { |file| File.join(JS::RUNTIME_DIR, file) })
  CAPACITY = 1000
  WIDTHS = { 1 => :byte, 2 => :half, 4 => :word }.freeze

  def test_each_list_is_kept_in_a_typed_array_of_its_width
    kept = harness_lines.to_h { |width, type, bytes, *| [width, [type, bytes]] }

    assert_equal({ 1 => ["Int8Array", CAPACITY], 2 => ["Int16Array", 2 * CAPACITY], 4 => ["Int32Array", 4 * CAPACITY] }, kept)
  end

  def test_a_narrow_slot_reads_back_as_the_interpreter_reads_it
    read = harness_lines.to_h { |width, _type, _bytes, *items| [width, items] }

    assert_equal WIDTHS.keys.to_h { |width| [width, interpreter_reads(WIDTHS.fetch(width))] }, read
  end

  private

  def harness_lines
    JS::Node.run_program(HARNESS, args: RUNTIME).lines.map do |line|
      width, type, bytes, *items = line.split
      [Integer(width), type, Integer(bytes), *items.map { |item| Integer(item) }]
    end
  end

  # The harness's steps as a game, played on the interpreter: the first and last items it reads.
  def interpreter_reads(width)
    builder = Builder.new
    builder.instance_eval do
      items = list :items, capacity: CAPACITY, width: width, full_of: 70_000
      items[1] = 200
      items.shift
      items.push(-70_000)
      halt
    end
    builder.finalize_program
    Reference.new.run(builder.program, frames: 1).list(:items).values_at(0, CAPACITY - 1)
  end
end
