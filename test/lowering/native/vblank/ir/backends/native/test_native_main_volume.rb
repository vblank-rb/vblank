# frozen_string_literal: true

require "test_helper"

# The main volume (`enable_sound main_volume:`) IN WHAT THE DESKTOP BUILD'S SPEAKER PLAYS: the whole
# mix, songs and effects alike, at that many 127ths of what the same game plays naming none. Played
# as the Advance, whose voices the runtime makes itself, and as the PlayStation, whose sound chip it
# plays (rg_spu.c), whose own main volume takes the setting. The JavaScript and Ruby runtimes are held
# to the C sample for sample (test/runtime_sounds.rb).
class TestNativeMainVolume < Minitest::Test
  # The frames, counted from the first heard, a held note and a held beep are measured over.
  MEASURED_FRAMES = 4..20

  # A tune of one held note, and a beep that holds, under +main_volume+ (nil: the game names none),
  # played as +console+.
  private def song_and_beep(main_volume, console)
    builder = VBlank::Builder.new
    builder.instance_eval do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      beep :hum
      game_loop { play_song :tune }
    end
    builder.finalize_program
    builder.program.tap { |program| program.console = console }
  end

  # The loudest the speaker gets over the measured frames.
  private def loudest(main_volume, console)
    heard = VBlank::Diagnostics::SoundRecording.of(song_and_beep(main_volume, console), on: :native, frames: 30)
    heard.frames.map(&:loudest).drop_while(&:zero?)[MEASURED_FRAMES].max
  end

  def test_the_mix_is_heard_at_the_share_named_as_the_advance
    assert_in_delta 96 / 127.0, loudest(96, :gba).fdiv(loudest(nil, :gba)), 0.01
  end

  def test_the_mix_is_heard_at_the_share_named_as_the_playstation
    assert_in_delta 96 / 127.0, loudest(96, :ps1).fdiv(loudest(nil, :ps1)), 0.01
  end

  def test_a_main_volume_of_nothing_is_silent
    heard = VBlank::Diagnostics::SoundRecording.of(song_and_beep(0, :gba), on: :native, frames: 30)

    assert_equal 0, heard.frames.map(&:loudest).max
  end

  def test_the_loudest_main_volume_is_the_same_sound_as_naming_none
    named, none = [127, nil].map do |main_volume|
      VBlank::Diagnostics::SoundRecording.of(song_and_beep(main_volume, :gba), on: :native, frames: 30).samples
    end

    assert_equal none, named
  end
end
