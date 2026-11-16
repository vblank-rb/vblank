# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_score_note_voices"

# A note's own rattle and its own waveform, as the Color's cartridge writes them: bit 3 of the
# noise voice's register (NR43, the seven-step counter that makes the rattle) for each drum hit, and
# the wave voice's memory for each wave note, read in the emulator frame by frame. What every run
# plays is test/all/vblank/audio/test_score_note_voices.rb's.
class TestGBCNoteVoices < Minitest::Test
  include ScoreNoteVoicesGames

  H = VBlank::Console::GBCHardware
  RATTLE_BIT = 0x08
  # What the player writes to NR43 for a rest (GBC::Music::REST's low byte).
  REST_CLOCK = 0xFF
  WAVE_BYTES = 16

  # What the block answers on each of the song's frames, with a run of the same answer kept once and
  # the frames it answers nil left out.
  private def each_change(frames: 40)
    b = rattle_and_wave_builder(options: VBlank::Cartridge::Options.new(console: :gbc))
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(b.program, title: "RATTLE")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 1)
    seen = Array.new(frames) { yield v.step }
    seen.chunk_while { |was, now| was == now }.map(&:first).reject(&:nil?) # false is an answer: a hit that does not rattle
  end

  def test_each_drum_hit_writes_the_rattle_its_note_says
    rattles = each_change do |v|
      clock = v.mem8(H::NR43)
      clock.anybits?(RATTLE_BIT) unless [REST_CLOCK, 0].include?(clock) # a rest, or no hit yet
    end

    assert_equal [true, false, true, false], rattles
  end

  # The wave voice's memory is read while the voice rests, as the console's own games read it.
  def test_each_wave_note_puts_its_own_waveform_in
    waves = each_change { |v| Array.new(WAVE_BYTES) { |n| v.mem8(H::WAVE_RAM + n) } unless v.mem8(H::NR30).anybits?(0x80) }
    # Two steps a byte, the first in the high four bits.
    wanted = [:sine, STEPPED, PART_WAVE, :sine].map do |shape|
      VBlank::Audio::Sound.wavetable(shape).each_slice(2).map { |high, low| (high << 4) | low }
    end

    assert_equal wanted, waves.drop_while { |bytes| !wanted.include?(bytes) }
  end
end
