# frozen_string_literal: true

# THE MAIN VOLUME OF ALL THE GAME'S SOUND (`enable_sound main_volume:`), played by each console whose
# build writes it to its sound chip: the Advance, the Color, the Super Nintendo and the PlayStation.
# The Genesis's chips have none, so its build refuses such a game (test/all/vblank/console/test_questions.rb).
#
# The interpreter logs the main volume as the sound is switched on, [:enabled, 96], and each checked
# run holds its build to that log on every frame or pass: the desktop, web and Ruby builds print it,
# and a cartridge's runtime says it as it switches its sound on. What the chip's registers then hold
# is each lowering's own test.
module MainVolumeTests
  # A held note of a song and a beep that holds, under +main_volume+ (nil: the game names none).
  private def main_volume_game(main_volume)
    builder = VBlank::Builder.new
    builder.instance_eval do
      main_volume ? enable_sound(main_volume: main_volume) : enable_sound
      define_sound :hum, frequency: 660, decay: :none, volume: 12
      song(:tune) { voice(:lead) { volume 15; note :A4, :whole } }
      beep :hum
      game_loop { play_song :tune }
    end
    builder.finalize_program
    builder.program
  end

  private def first_sound(main_volume) = game_player.run(main_volume_game(main_volume), frames: 8).audio.first

  def test_the_main_volume_named_is_logged_as_the_sound_switches_on
    assert_equal [:enabled, 96], first_sound(96)
  end

  def test_a_share_is_logged_as_that_many_127ths
    assert_equal [:enabled, 64], first_sound(0.5)
  end

  def test_a_main_volume_of_nothing_is_logged
    assert_equal [:enabled, 0], first_sound(0)
  end

  def test_a_game_that_names_none_logs_none
    assert_equal [:enabled], first_sound(nil)
  end
end
