# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "tmpdir"

# THE PACE OF A LONG UNPACKING BUILT AS RUBY, WRITTEN AS LOOPS. A port that renders a sound chip
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
# smaller, held to a pace the `case` did not keep, and to the pack the all-in-one build made. Its
# list reads are too few to time apart from the machine's noise; Wolfenstein's are what measured them.
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

  # Measured where this was written, the routine took over twice as long with its steps picked by a
  # `case`, and this bound lies between the two: a run on a busy machine keeps it, and the `case`
  # brought back does not.
  MOST_SECONDS = 2.0

  def test_a_looped_unpacking_plays_at_pace_as_ruby
    assert RubyVM::YJIT.enabled?, "The Ruby run plays with YJIT (Testing::Lowering::RUNS), and this one has none"
    Dir.mktmpdir do |folder|
      copy = (0...256).map { |at| (at * 37) & 0xFF }.pack("C*")
      b = VBlank::Builder.new
      made = looped_pack(b, copy_of(folder, copy))
      game = VBlank::IR::Backends::Ruby.new.live_game(made.unpacking.program).hand_file(copy)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(1_000_000))
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      pack = VBlank::Original::Pack.from_bytes(b.made_data_pack_file)
      written = game.state(byte_lists_packed: true).lists.fetch(VBlank::Original::Unpacking::BYTES.to_s).b
      assert_equal pack.bytes_of(:head) + pack.bytes_of(:samples), written,
                   "the pack the Ruby unpacking makes is the all-in-one build's"
      assert_operator seconds, :<, MOST_SECONDS, "the unpacking took #{seconds} s as Ruby"
    end
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
