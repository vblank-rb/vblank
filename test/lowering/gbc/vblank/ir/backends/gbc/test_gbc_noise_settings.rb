# frozen_string_literal: true

require "test_helper"

# A drum's own noise setting, as the Color's cartridge tells its noise voice (NR43): the divider in
# the low three bits and how many times it is halved in the top four. Two settings can step at the
# same rate, and a song converted from another Game Boy game names the one that game wrote. What
# the drum sounds like on every run is test/all/vblank/audio/test_scores.rb's.
class TestGBCNoiseSettings < Minitest::Test
  H = VBlank::Console::GBCHardware
  Score = VBlank::Audio::Score

  private def nr43_for(note)
    drums = Score.new(tempo: 150, parts: [Score::Part.new(plays: :noise, notes: [note])])
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [drums]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(b.program, title: "NOISE")
    VBlank::Diagnostics::Verifier.new(rom, frames: 12).mem8(H::NR43)
  end

  def test_a_drum_is_written_with_its_own_noise_setting
    assert_equal 0x11, nr43_for(Score::Note.new(at: 0, noise_clock: [1, 1]))
  end

  # The same rate said as a rate takes the first setting that makes it.
  def test_a_drum_said_by_its_rate_takes_the_first_setting_that_makes_it
    assert_equal 0x20, nr43_for(Score::Note.new(at: 0, hz: 131_072))
  end
end
