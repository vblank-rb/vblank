# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "open3"
require "tmpdir"

# The pace of a long unpacking on the web. A port's unpacking routine is built as the port's Ruby
# unrolls it, so it is one long routine with a wait for the next frame inside its busiest loop (a
# port rendering its music writes a sample at a time, and waits every few hundred). Printed whole,
# V8 never optimised it, and Wolfenstein's shareware took minutes to unpack in a web shell where its
# C took seconds. This is such a routine, smaller: a loop of samples, each the sum of many voices
# written out one after another, played as a web shell's worker plays it (unpacking_harness.js), and
# held to the pack the all-in-one build made.
#
# Counted, not timed. A time fails whenever other work shares the cores, so what made the routine
# slow is counted in the JavaScript it is printed as, which no load can change: the lines of its
# longest function (V8 gives up optimising a function past a size, and the sample loop printed whole
# is thousands of lines), and the game's sums written as calls into the runtime (rg_add and its
# siblings) where JavaScript's own operators do (JS::Printer::OPERATORS).
class TestJSUnpackingPace < Minitest::Test
  include MadeUpOriginal

  HARNESS = File.join(__dir__, "unpacking_harness.js")

  VOICES = 600
  SAMPLES = 60_000

  # The most lines one function of the routine may have. Printed in parts (JS::Printer
  # MOST_WEIGHT_A_FUNCTION), its longest was a few hundred where this was written; printed whole,
  # the sample loop's one function is four lines a voice.
  MOST_LINES_A_FUNCTION = 1_000

  # The runtime's functions for a sum of two numbers, which the printer writes as operators.
  SUM_CALLS = /\brg_(?:add|sub|mul|and|or|xor)\(/

  def test_a_long_unpacking_is_printed_in_parts_with_its_sums_as_operators
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
      _out, said, status = Open3.capture3("node", HARNESS, factory, File.join(folder, "copy.bin"),
                                          VBlank::Original::Unpacking::BYTES.to_s, File.join(folder, "made.bin"))
      assert status.success?, said

      assert_equal VBlank::Original::Pack.from_bytes(b.made_data_pack_file).bytes_of(:samples), File.binread(File.join(folder, "made.bin")),
                   "the pack the web shell makes is the all-in-one build's"
      routine = routine_functions(text)
      assert_operator routine.map { |function| function.lines.length }.max, :<=, MOST_LINES_A_FUNCTION, "lines of the longest function"
      assert_equal 0, routine.sum { |function| function.scan(SUM_CALLS).length }, "sums written as calls into the runtime"
    end
  end

  # The functions the routine is printed as (rg_game_main, and its steps and parts), each its text:
  # every function of the file starts a line with `function`, and the game's are named for it.
  private def routine_functions(text)
    text.split(/^(?=function )/).grep(/\Afunction rg_(?:game_main|steps_\d+_rg_game_main|part_\d+_rg_game_main)\(/)
  end
end
