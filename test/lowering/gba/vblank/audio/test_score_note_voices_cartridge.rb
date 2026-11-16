# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_score_note_voices"

# A note's own rattle and its own waveform, as the Advance's cartridge writes them: bit 3 of the
# noise voice's register (SOUND4CNT_H, the seven-step counter that makes the rattle) for each drum
# hit, and the wave voice's memory for each wave note, read in the emulator frame by frame. What
# every run plays is test/all/vblank/audio/test_score_note_voices.rb's.
class TestScoreNoteVoicesCartridge < Minitest::Test
  include ScoreNoteVoicesGames

  H = VBlank::Console::Hardware
  RATTLE_BIT = 0x0008
  WAVE_HALFWORDS = 8

  # What the block answers on each of the song's frames, with a run of the same answer kept once and
  # the frames it answers nil left out.
  private def each_change(program = rattle_and_wave_game, frames: 40)
    v = assert_emulator_loads_rom(assemble_rom(program, name: "RATTLE"), frames: 1)
    seen = Array.new(frames) { yield v.step }
    seen.chunk_while { |was, now| was == now }.map(&:first).reject(&:nil?) # false is an answer: a hit that does not rattle
  end

  def test_each_drum_hit_writes_the_rattle_its_note_says
    rattles = each_change do |v|
      register = v.mem16(H::REG_SOUND4CNT_H)
      register.anybits?(RATTLE_BIT) unless (register & 0xFF).zero? # a rest names no clock
    end

    assert_equal [true, false, true, false], rattles
  end

  def test_each_wave_note_puts_its_own_waveform_in
    waves = each_change { |v| Array.new(WAVE_HALFWORDS) { |n| v.mem16(H::REG_WAVE_RAM + (2 * n)) } }
    wanted = [:sine, STEPPED, PART_WAVE, :sine].map { |shape| VBlank::IR::Backends::GameBoySound.wavetable_halfwords(shape) }

    assert_equal wanted, waves.drop_while { |table| !wanted.include?(table) }
  end

  # The same parts as a sound effect: an effect's wave row names its note's waveform too.
  def test_a_sound_effects_wave_notes_put_their_own_waveforms_in
    waves = each_change(rattle_and_wave_effect_game) { |v| Array.new(WAVE_HALFWORDS) { |n| v.mem16(H::REG_WAVE_RAM + (2 * n)) } }
    wanted = [:sine, STEPPED, PART_WAVE, :sine].map { |shape| VBlank::IR::Backends::GameBoySound.wavetable_halfwords(shape) }

    assert_equal wanted, waves.drop_while { |table| !wanted.include?(table) }
  end
end
