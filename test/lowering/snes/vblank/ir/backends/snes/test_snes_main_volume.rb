# frozen_string_literal: true

require "test_helper"

# THE SOUND CHIP'S MAIN VOLUME (`enable_sound main_volume:`), read from the S-DSP's own registers
# and heard in the sound bsnes plays. The main volume scales everything the chip mixes, songs and
# effects alike, after each voice's own volume: a game that names 96 is heard 96/127 as loud as the
# same game left at the loudest. Each run is checked against the interpreter's sound log on every
# pass, so the registers agree with what the log says the game asked for.
class TestSNESMainVolume < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # The S-DSP's main volume, left and right (fullsnes, "SNES APU DSP Volume Registers").
  MAIN_LEFT = SNES::DSPWrites::MAIN_LEFT
  MAIN_RIGHT = SNES::DSPWrites::MAIN_RIGHT

  # The frames, counted from the first heard, a held note and a held beep are measured over.
  MEASURED_FRAMES = 4..20

  # A tune of one held note, and a beep that holds, under +main_volume+ (nil: the game names none).
  private def song_and_beep(main_volume)
    VBlank.game("MAINVOLUME", consoles: %i[snes]) do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      beep :hum
      game_loop { play_song :tune }
    end.program(console: :snes)
  end

  private def play_checked(program) = SNES::CheckedRun.new.run(program, frames: 30)

  # The interpreter's log names it as the sound is switched on, which is what the checked run holds
  # the registers to; the cartridge's log names it too.
  def test_the_main_volume_named_is_in_both_registers
    run = play_checked(song_and_beep(96))
    registers = run.dsp_registers

    assert_equal [:enabled, 96], run.audio.first
    assert_equal [96, 96], [registers.getbyte(MAIN_LEFT), registers.getbyte(MAIN_RIGHT)]
  end

  def test_a_share_is_of_the_loudest_the_chip_has
    registers = play_checked(song_and_beep(0.5)).dsp_registers

    assert_equal [64, 64], [registers.getbyte(MAIN_LEFT), registers.getbyte(MAIN_RIGHT)]
  end

  def test_a_game_that_names_none_plays_at_the_loudest
    registers = play_checked(song_and_beep(nil)).dsp_registers

    assert_equal [127, 127], [registers.getbyte(MAIN_LEFT), registers.getbyte(MAIN_RIGHT)]
  end

  # The song's note and the beep together, heard: the main volume scales the whole mix.
  def test_the_song_and_the_beep_are_heard_at_the_share_named
    full, quieter = [nil, 96].map do |main_volume|
      play_checked(song_and_beep(main_volume)).loudest_each_frame.drop_while(&:zero?)[MEASURED_FRAMES].max
    end

    assert_in_delta 96 / 127.0, quieter.fdiv(full), 0.03
  end
end
