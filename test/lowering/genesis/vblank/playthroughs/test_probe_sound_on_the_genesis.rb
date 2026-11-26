# frozen_string_literal: true

require "test_helper"
require "stringio"

# A probe on a Genesis cartridge lists every write the game made to its sound chips in a step, oldest
# first (Diagnostics::GenesisReading#watch_sound): the square voices' bytes, and the FM chip's registers.
class TestProbeSoundOnTheGenesis < Minitest::Test
  ChipWrites = VBlank::IR::Backends::Genesis::ChipWrites

  NOTES_PASS = 20
  # The FM chip's key-on register, and its value for the wave's voice.
  KEY_ON = 0x28
  KEY_ON_VALUE = 0xF0

  # Thirty samples of a square wave, up then down.
  CLIP = (([100] * 15) + ([-100] * 15)).freeze

  private def two_notes_game
    VBlank.build("NOTES", console: :genesis, out: StringIO.new, err: StringIO.new) do
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

  def test_the_writes_a_game_made_to_its_sound_chips_are_listed_by_frame_in_order
    writes = VBlank::Playthroughs::Probe.open(two_notes_game) do |probe|
      probe.watch_sound
      (1..(NOTES_PASS * 2)).flat_map { |frame| probe.step.sound_writes.each_with_index.map { |write, at| [frame, at, write] } }
    end
    loud = 0x90 | (ChipWrites::BEEP_VOICE << 5) | ChipWrites::ATTENUATION[12]
    beep = writes.find { |_, _, write| write.chip == :psg && write.value == loud }
    key_on = writes.find { |_, _, write| write.chip == :fm && write.address == KEY_ON && write.value == KEY_ON_VALUE }

    assert beep, "the beep's loudness byte is listed"
    assert key_on, "the wave's key-on is listed"
    assert_equal beep.first, key_on.first, "both in one frame"
    assert_operator writes.index(beep), :<, writes.index(key_on), "the beep first"
    assert(writes.all? { |_, _, write| write.value.between?(0, 255) }, "a value is the byte written")
    assert(writes.all? { |_, _, write| write.chip == :psg || write.address <= 0x1FF }, "an FM register has nine bits")
  end

  # The sound processor writes the DAC's sample and the timers every sample of a recording: they start
  # no note, and are not listed.
  def test_a_genesis_game_playing_a_recording_lists_no_dac_samples
    rom = VBlank.build("CLIP", console: :genesis, out: StringIO.new, err: StringIO.new) do
      enable_sound
      sample(:clip, pcm: CLIP, rate: 13_000).play(loop: true)
      game_loop { nil }
    end
    writes = VBlank::Playthroughs::Probe.open(rom) do |probe|
      probe.watch_sound
      Array.new(20) { probe.step.sound_writes }.flatten
    end

    refute(writes.any? { |write| write.chip == :fm && ([0x2A] + (0x24..0x27).to_a).include?(write.address) }, "no sample or timer is listed")
  end
end
