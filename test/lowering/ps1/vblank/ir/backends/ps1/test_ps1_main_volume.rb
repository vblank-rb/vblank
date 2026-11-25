# frozen_string_literal: true

require "test_helper"

# The main volume (`enable_sound main_volume:`) as the PlayStation program writes it: the sound chip's
# main volume, left and right, read from its registers in Beetle PSX. Its loudest is 3FFFh, which is
# 127 times 129, so a number of 127ths is that many 129ths of it, exactly. The checked run holds the
# registers to the interpreter's log on every pass (SPUWrites.after).
class TestPS1MainVolume < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  H = VBlank::Console::PS1Hardware

  # The main volume registers, by their distance from 1F801C00h.
  MAIN_LEFT = H::SPU_MAIN_VOLUME - H::SPU
  MAIN_RIGHT = MAIN_LEFT + 2

  # A held note of a song and a beep that holds, under +main_volume+ (nil: the game names none).
  private def song_and_beep(main_volume)
    VBlank.game("MAINVOLUME", consoles: %i[ps1]) do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      beep :hum
      game_loop { play_song :tune }
    end.program(console: :ps1)
  end

  private def main_registers(main_volume)
    registers = PS1::CheckedRun.new.run(song_and_beep(main_volume), frames: 6).spu_reads.last.last
    [registers.fetch(MAIN_LEFT), registers.fetch(MAIN_RIGHT)]
  end

  def test_the_main_volume_named_is_in_both_registers
    assert_equal [96 * 129, 96 * 129], main_registers(96)
  end

  def test_a_main_volume_of_nothing_is_nothing
    assert_equal [0, 0], main_registers(0)
  end

  def test_a_game_that_names_none_plays_at_the_loudest
    assert_equal [H::SPU_MAIN_LOUDEST, H::SPU_MAIN_LOUDEST], main_registers(nil)
  end
end
