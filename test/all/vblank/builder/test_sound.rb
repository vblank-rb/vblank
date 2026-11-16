# frozen_string_literal: true

require "test_helper"

# The friendly errors a sound verb raises. That each sound builds into the Advance's cartridge,
# the numbers its registers are given, and the cartridge playing a sound in the emulator are in
# test/lowering/gba/vblank/builder/test_sound_cartridge.rb.
class TestSound < Minitest::Test
  include VBlank::Console::Hardware

  private def build(validate: false, &block)
    VBlank.build("SNDTEST", console: :gba, code: "BSND", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # enable_sound
  # ========================================================================

  def test_enable_sound_twice_raises
    assert_raises(ArgumentError) do
      build do
        enable_sound
        enable_sound
        halt
      end
    end
  end

  # A game naming the rate its recordings are mixed at asks for that rate, whatever its recordings'
  # own: what a port names when its recordings' rates come from its data pack.
  def test_enable_sound_names_the_rate_the_mix_is_asked_to_run_at
    named = Builder.new
    named.instance_eval do
      enable_sound mix_rate: 13_379
      sample :clip, pcm: [0, 40, 80, 40] * 8, rate: 8000
    end
    plain = Builder.new
    plain.instance_eval do
      enable_sound
      sample :clip, pcm: [0, 40, 80, 40] * 8, rate: 8000
    end

    assert_equal 13_379, VBlank::IR::Mixing.requested_rate(named.program)
    assert_equal 8000, VBlank::IR::Mixing.requested_rate(plain.program)
  end

  def test_enable_sound_refuses_a_mix_rate_that_is_no_rate
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { enable_sound mix_rate: 12.5 } }
    assert_includes error.message, "mix_rate"
  end

  def test_enable_sound_refuses_a_main_volume_that_is_no_volume
    [128, -1, 1.5, "loud"].each do |volume|
      error = assert_raises(ArgumentError) { Builder.new.instance_eval { enable_sound main_volume: volume } }
      assert_includes error.message, "main_volume", volume.inspect
    end
  end

  # ========================================================================
  # Error handling
  # ========================================================================

  def test_beep_without_enable_sound_raises
    assert_raises(ArgumentError) do
      build do
        beep 440
        halt
      end
    end
  end

  def test_beep_unknown_preset_raises
    assert_raises(ArgumentError) do
      build do
        beep :nonexistent
        halt
      end
    end
  end

  def test_beep_unknown_duty_raises
    assert_raises(ArgumentError) do
      build do
        beep 440, duty: :invalid
        halt
      end
    end
  end

  def test_beep_unknown_decay_raises
    assert_raises(ArgumentError) do
      build do
        beep 440, decay: :invalid
        halt
      end
    end
  end

  # ========================================================================
  # noise — the percussion / explosion voice
  # ========================================================================

  def test_noise_before_enable_sound_raises
    err = assert_raises(ArgumentError) do
      build do
        noise :hit
        halt
      end
    end
    assert_match(/enable_sound before noise/, err.message)
  end

  # ========================================================================
  # wave — the programmable wave voice (channel 3)
  # ========================================================================

  def test_wave_before_enable_sound_raises
    err = assert_raises(ArgumentError) do
      build do
        wave :sine, :C4
        halt
      end
    end
    assert_match(/enable_sound before wave/, err.message)
  end

  def test_wave_with_an_unknown_note_raises
    err = assert_raises(ArgumentError) do
      build do
        enable_sound
        wave :sine, :Z9
        halt
      end
    end
    assert_match(/not known/, err.message)
  end
end
