# frozen_string_literal: true

require "test_helper"
require "stringio"

# A probe on a Super Nintendo cartridge lists every write to its sound unit in a step, oldest first
# (Diagnostics::SNESReading#watch_sound): the game's writes to the four ports it asks its sound
# program through ($2140 to $2143), and that program's writes to the S-DSP's registers, each with the
# sample and the master clock it landed on. The S-DSP starts a voice when its bit of KON (0x4C) is
# written (fullsnes, "SNES APU DSP BRR/Voice Key On/Off").
class TestProbeSoundOnTheSuperNintendo < Minitest::Test
  NOTES_PASS = 20
  KEY_ON = 0x4C
  PORTS = (0x2140..0x2143)

  private def two_notes_code
    proc do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        if count == NOTES_PASS
          beep 880, duty: :half, decay: :none, volume: 12
          wave :sawtooth, :A3, volume: :half
        end
      end
    end
  end

  # Each write the probe lists, with the frame its step played.
  private def writes_by_frame(frames)
    rom = VBlank.build("NOTES", console: :snes, out: StringIO.new, err: StringIO.new, &two_notes_code)
    VBlank::Playthroughs::Probe.open(rom) do |probe|
      probe.watch_sound
      (1..frames).flat_map { |frame| probe.step.sound_writes.map { |write| [frame, write] } }
    end
  end

  # The frame the interpreter plays both notes on, from its sound log.
  private def interpreter_notes_frame
    builder = Builder.new
    builder.instance_eval(&two_notes_code)
    builder.finalize_program
    run = Reference.new
    found = nil
    seen = 0
    frame = 0
    run.each_vblank do
      frame += 1
      found ||= frame if run.audio.drop(seen).any? { |entry| %i[beep wave].include?(entry.first) }
      seen = run.audio.size
    end
    run.run(builder.program.copy.tap { |program| program.console = :snes }, frames: NOTES_PASS * 2)
    found
  end

  def test_both_key_ons_are_listed_in_order_after_the_game_asks
    writes = writes_by_frame(NOTES_PASS * 2)
    key_ons = writes.select { |_, write| write.chip == :dsp && write.address == KEY_ON && write.value.positive? }
    asks = writes.select { |_, write| write.chip == :port && PORTS.cover?(write.address) }

    voices = key_ons.map { |_, write| write.value }
    assert_equal 2, voices.sum { |bits| bits.to_s(2).count("1") }, "two voices keyed on: #{voices.inspect}"
    assert_equal [key_ons.first.first], key_ons.map(&:first).uniq, "both in one frame"
    asked_before = asks.select { |_, write| write.clock < key_ons.first.last.clock }
    refute_empty asked_before, "the game asked through the ports before the first key-on"
    assert_operator asked_before.last.last.sample, :<=, key_ons.first.last.sample, "the ask's sample comes first"
  end

  # Each write's sample, and each port write's clock, never goes back.
  def test_the_samples_and_the_clocks_run_forward
    writes = writes_by_frame(NOTES_PASS + 5).map(&:last)
    dsp = writes.select { |write| write.chip == :dsp }
    ports = writes.select { |write| write.chip == :port }

    refute_empty dsp
    refute_empty ports
    assert_equal dsp.map(&:sample).sort, dsp.map(&:sample)
    assert_equal ports.map(&:clock).sort, ports.map(&:clock)
    assert(writes.all? { |write| write.value.between?(0, 255) }, "a value is the byte written")
  end

  # The key-ons are on the frame of the pass that asked for the notes, as the interpreter plays them on
  # the frame of that pass. The cartridge's frames count from power-on, with frames of its own setting
  # up before the first pass, so the pass is told by the game's own count.
  def test_the_key_ons_land_on_the_frame_of_the_pass_that_asked
    rom = VBlank.build("NOTES", console: :snes, out: StringIO.new, err: StringIO.new, &two_notes_code)
    counts = VBlank::Playthroughs::Probe.open(rom) do |probe|
      probe.watch_sound
      Array.new(NOTES_PASS * 2) do
        probe.step
        keyed = probe.sound_writes.any? { |write| write.chip == :dsp && write.address == KEY_ON && write.value.positive? }
        [probe.reader.var(:count), keyed]
      end
    end

    assert_equal [NOTES_PASS], counts.select(&:last).map(&:first)
    assert_equal interpreter_notes_frame, NOTES_PASS + 1, "the interpreter plays them on the pass's frame, after the frame that sets up"
  end
end
