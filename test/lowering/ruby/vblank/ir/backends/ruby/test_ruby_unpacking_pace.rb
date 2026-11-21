# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "prism"
require "tmpdir"

# The pace of a long unpacking built as Ruby, written as loops. A port that renders a sound chip
# into its pack keeps each of the chip's operators as an item of lists, one list a field, and
# every sample goes round the operators in a `repeat`, reading those lists at the operator's number
# as it runs. The routine writes a byte a sample and waits for the next frame every few hundred,
# so the sample loop is cut into steps, and the routine has hundreds of steps before it from the
# pack's other parts.
#
# Wolfenstein's shareware, rewritten that way, unpacked in five minutes as Ruby where the routine
# written out once per operator took three. Most of that was each turn of the cut loop picking its
# step from a `case` that YJIT, having seen hundreds of steps, tested `when` by `when`
# (Printer#print_step_choice halves instead); the rest, list reads that were a chain of small calls
# (RgList#get is one, and an always-full list's read is its Array's own). This is such a routine,
# smaller, held to the pack the all-in-one build made, and to the work a turn of its loop does.
#
# Counted, not timed. A time fails whenever other work shares the cores, so the work is counted in
# the routine as it is printed, which no load can change: the most tests of the step counter a turn
# makes to pick its step (a `case`, which YJIT tests `when` by `when`, counts a test for each `when`),
# and the list items it reads or writes through the list's own method rather than its Array's.
class TestRubyUnpackingPace < Minitest::Test
  include MadeUpOriginal

  OPERATORS = 18
  SAMPLES = 100_000
  # Parts of the pack filled before the samples, each a loop of its own that writes and counts what
  # it wrote, so each adds steps before the sample loop's. Each is long enough to wait for a frame
  # more than once, so the routine has been called many times, and YJIT has compiled it, while those
  # steps are still being picked.
  PARTS_BEFORE = 150
  PART_BYTES = 600

  # The most tests of the step counter a turn may make. The routine has hundreds of steps, which
  # halving picks among in about ten tests and a `case` in hundreds; this is a few over what the
  # halving made where this was written.
  MOST_STEP_TESTS = 14

  def test_a_looped_unpacking_picks_its_step_by_halving_and_reads_its_lists_in_place
    Dir.mktmpdir do |folder|
      copy = (0...256).map { |at| (at * 37) & 0xFF }.pack("C*")
      b = VBlank::Builder.new
      made = looped_pack(b, copy_of(folder, copy))
      printed = Prism.parse(VBlank::IR::Backends::Ruby.new.live_source(made.unpacking.program)).value
      game = VBlank::IR::Backends::Ruby.new.live_game(made.unpacking.program).hand_file(copy)
      game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(1_000_000))

      pack = VBlank::Original::Pack.from_bytes(b.made_data_pack_file)
      written = game.state(byte_lists_packed: true).lists.fetch(VBlank::Original::Unpacking::BYTES.to_s).b
      assert_equal pack.bytes_of(:head) + pack.bytes_of(:samples), written,
                   "the pack the Ruby unpacking makes is the all-in-one build's"
      assert_operator most_step_tests(printed), :<=, MOST_STEP_TESTS, "tests of the step counter to pick a step"
      assert_equal 0, list_method_items(printed).length, "list items read or written through the list's own method"
    end
  end

  # The most tests of the step counter (`rg_step`) one pick of a step makes, below +node+: an `if`
  # or `elsif` on the counter is one, and a `case` on it one for each `when`.
  private def most_step_tests(node)
    below = node.compact_child_nodes.map { |child| most_step_tests(child) }.max || 0
    case node
    when Prism::IfNode then step_test?(node.predicate) ? 1 + below : below
    when Prism::CaseNode then step_test?(node.predicate) ? node.conditions.length + below : below
    else below
    end
  end

  private def step_test?(predicate) = predicate&.slice&.match?(/\brg_step\b/)

  # The calls below +node+ that read or write a list item through the list's own method (RgList#get
  # and #set, Printer#list_item_call) rather than its Array's.
  private def list_method_items(node)
    found = node.compact_child_nodes.flat_map { |child| list_method_items(child) }
    list_method_item?(node) ? [node, *found] : found
  end

  private def list_method_item?(node)
    node.is_a?(Prism::CallNode) && %i[get set].include?(node.name) && node.receiver.is_a?(Prism::InstanceVariableReadNode)
  end

  # The pack: PARTS_BEFORE short loops, then a sample loop round OPERATORS operators kept as lists.
  private def looped_pack(builder, from)
    operators = OPERATORS
    samples = SAMPLES
    parts = PARTS_BEFORE
    part_bytes = PART_BYTES
    made = nil
    builder.instance_eval do
      made = data_pack(from: from, version: "1") do |slots|
        slots.numbers :head, count: parts * part_bytes, width: :byte, signed: false
        slots.numbers :samples, count: samples, width: :byte, signed: false
        slots.fill_from_copy do |reader, pack|
          parts.times do |part|
            repeat(part_bytes) do |at|
              pack[:head][(part * part_bytes) + at] = reader.byte(at & 0xFF) ^ (part & 0xFF)
              reader.count_written 1
            end
          end
          phase = list(:pace_phase, capacity: operators, full_of: 0)
          step = list(:pace_step, capacity: operators, full_of: 0)
          stage = list(:pace_stage, capacity: operators, full_of: 0)
          loss = list(:pace_loss, capacity: operators, full_of: 0)
          sine = table(:pace_sine, (0...256).map { |at| (Math.sin(at * Math::PI / 128) * 2000).round }, width: :half)
          total = var(:pace_total, 0)
          repeat(operators) do |op|
            step[op] = reader.byte(op) + 1
            stage[op] = op & 1
          end
          repeat(samples) do |at|
            total.store!(0)
            repeat(operators) do |op|
              phase[op] = (phase[op] + (step[op] * stage[op])) & 0xFFFF
              loss[op] = (loss[op] + 1) & 0xFF
              total.store!(total + ((sine[phase[op] >> 8] * (256 - loss[op])) >> 8))
            end
            pack[:samples][at] = total >> 6
            reader.count_written 1
          end
        end
      end
    end
    made
  end
end
