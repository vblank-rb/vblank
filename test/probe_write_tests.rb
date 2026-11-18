# frozen_string_literal: true

require "tmpdir"

# A PROBE PUTS A VALUE INTO A RUNNING CARTRIDGE'S MEMORY, AND SAVES AND RESTORES THE WHOLE CONSOLE,
# on every console whose emulator a probe opens. The game counts its passes, and copies a number
# (hearts) into another (shown) on every pass, changing hearts itself only when START is pressed,
# which no test here does. So a value written is seen by the game's own code the next pass, read in
# the processor's own byte order. Each including test says +console+.
module ProbeWriteTests
  private def written_game
    VBlank.build("WRITTEN", console: console, out: nil, err: nil) do
      var :before, 0x1234
      hearts = var :hearts, 3
      var :after, 0x5678
      shown = var :shown, 0
      count = var :count, 0
      game_loop do
        count += 1
        hearts += 1 if pressed(:start) # never pressed here, so the build keeps hearts in memory
        shown = hearts
      end
    end
  end

  # The probe on the game, played until it has started and run a pass.
  private def probe_on(cartridge)
    VBlank::Playthroughs::Probe.open(cartridge) do |probe|
      probe.step_until_started(within: 120)
      probe.step_until("the first pass over", within: 120) { probe.var(:count) > 1 }
      yield probe
    end
  end

  # How +name+ is kept, as a width the probe reads (Playthroughs::Probe::WIDTHS), and where in it
  # its lowest byte is: first on the 65816 and the R3000, last on the 68000.
  private def kept_width(built, name)
    bytes = built.built.respond_to?(:variable_bytes) ? built.built.variable_bytes(name) : 4
    { 2 => :s16, 4 => :s32 }.fetch(bytes)
  end

  private def low_byte_offset(width) = console == :genesis ? VBlank::Playthroughs::Probe::WIDTHS.fetch(width).bytes - 1 : 0

  def test_a_value_written_is_read_back_and_seen_by_the_game
    built = written_game
    at = built.var_addresses.fetch(:hearts)
    width = kept_width(built, :hearts)
    probe_on(built) do |probe|
      before = probe.read_bytes(at - 4, 4)
      after = probe.read_bytes(at + 4, 4)
      probe.write(at, 9, as: width)

      assert_equal 9, probe.read(at, as: width), "read back on the frame it was written"
      assert_equal [0x1234, 0x5678], [probe.var(:before), probe.var(:after)], "the variables beside it"
      assert_equal [before, after], [probe.read_bytes(at - 4, 4), probe.read_bytes(at + 4, 4)], "the bytes beside it"
      probe.step_until("the game showing 9", within: 10) { probe.var(:shown) == 9 }
    end
  end

  # One byte written into the middle of a word lands where the processor keeps that byte.
  def test_a_byte_written_is_the_byte_the_processor_keeps_there
    built = written_game
    at = built.var_addresses.fetch(:hearts)
    width = kept_width(built, :hearts)
    probe_on(built) do |probe|
      probe.write(at + low_byte_offset(width), 5, as: :u8)

      assert_equal 5, probe.var(:hearts)
    end
  end

  def test_a_saved_state_puts_the_game_back
    Dir.mktmpdir("states") do |folder|
      probe_on(written_game) do |probe|
        probe.step(5)
        saved_at = probe.frame
        counted = probe.var(:count)
        state = File.join(folder, "counted.state")
        probe.save_state(state)
        probe.step(10)
        refute_equal counted, probe.var(:count)

        probe.load_state(state, frame: saved_at)

        assert_equal counted, probe.var(:count)
        assert_equal saved_at, probe.frame
        probe.step(3)
        assert_operator probe.var(:count), :>, counted, "the game plays on from the state"
      end
    end
  end
end
