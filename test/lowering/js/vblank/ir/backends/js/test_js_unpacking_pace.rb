# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "open3"
require "tmpdir"

# THE PACE OF A LONG UNPACKING ON THE WEB. A port's unpacking routine is built as the port's Ruby
# unrolls it, so it is one long routine with a wait for the next frame inside its busiest loop (a
# port rendering its music writes a sample at a time, and waits every few hundred). Printed whole,
# V8 never optimised it, and Wolfenstein's shareware took minutes to unpack in a web shell where its
# C took seconds. This is such a routine, smaller: a loop of samples, each the sum of many voices
# written out one after another, played as a web shell's worker plays it (unpacking_harness.js), and
# held to a pace the routine printed whole did not keep, and to the pack the all-in-one build made.
class TestJSUnpackingPace < Minitest::Test
  include MadeUpOriginal

  HARNESS = File.join(__dir__, "unpacking_harness.js")

  VOICES = 600
  SAMPLES = 60_000

  # Measured where this was written, the routine printed whole took over ten times as long as in
  # parts with its sums written as operators, and this bound lies between the two, nearer the
  # whole: a run on a busy machine keeps it, and a routine printed whole again does not.
  MOST_SECONDS = 1.2

  def test_a_long_unpacking_plays_at_pace_on_the_web
    voices = VOICES
    samples = SAMPLES
    Dir.mktmpdir do |folder|
      copy = (0...voices).map { |at| (at * 37) & 0xFF }.pack("C*")
      from = copy_of(folder, copy)
      b = VBlank::Builder.new
      made = nil
      b.instance_eval do
        made = data_pack(from: from, version: "1") do |slots|
          slots.numbers :samples, count: samples, width: :byte, signed: false
          slots.fill_from_copy do |reader, pack|
            phases = Array.new(voices) { |voice| var(:"pace_phase_#{voice}", 0) }
            total = var(:pace_total, 0)
            repeat(samples) do |at|
              total.store!(0)
              phases.each_with_index do |phase, voice|
                phase.store!((phase + reader.byte(voice) + voice + 1) & 0xFFFF)
                total.store!(total + ((phase >> 6) ^ (phase & 0x3F)))
              end
              pack[:samples][at] = total >> 3
              reader.count_written 1
            end
          end
        end
      end
      unpacking = made.unpacking
      factory = File.join(folder, "unpacking.js")
      text, = VBlank::IR::Backends::JS.new.factory_and_data_file(unpacking.program, name: "createUnpacking", menu: false, states: false)
      File.write(factory, "\"use strict\";\n#{text}\nmodule.exports = createUnpacking;\n")
      File.binwrite(File.join(folder, "copy.bin"), copy)
      out, said, status = Open3.capture3("node", HARNESS, factory, File.join(folder, "copy.bin"),
                                         VBlank::Original::Unpacking::BYTES.to_s, File.join(folder, "made.bin"))
      assert status.success?, said
      seconds = Integer(out[/^played (\d+)$/, 1]) / 1000.0

      assert_equal VBlank::Original::Pack.from_bytes(b.made_data_pack_file).bytes_of(:samples), File.binread(File.join(folder, "made.bin")),
                   "the pack the web shell makes is the all-in-one build's"
      assert_operator seconds, :<, MOST_SECONDS, "the unpacking took #{seconds} s on the web"
    end
  end
end
