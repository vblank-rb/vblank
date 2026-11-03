# frozen_string_literal: true

require "test_helper"
require "differential"
require "sprite_over_picture_games"

# A SPRITE OVER A PAINTED PICTURE ON THE ADVANCE'S CARTRIDGE: the console's own sprite drawn over
# the bitmap screen, read in the emulator and held to the interpreter pixel for pixel. What the
# sprite does, asked of every run, is in test/all/vblank/builder/test_sprite_over_picture.rb.
class TestSpriteOverPictureCartridge < Minitest::Test
  include Differential
  include SpriteOverPictureGames

  def test_the_cartridge_shows_the_sprite_over_a_direct_colour_screen
    assert_backends_agree(over_picture_program, frames: [3, 6])
  end

  def test_the_cartridge_shows_a_moving_sprite_over_a_direct_colour_screen
    assert_backends_agree(over_picture_program(step: 3), frames: [4, 7])
  end

  def test_the_cartridge_shows_the_sprite_over_both_pages_of_a_tear_free_screen
    assert_backends_agree(over_picture_program(step: 2, tear_free: true), frames: 1..6)
  end

  def test_the_cartridge_draws_the_sprite_with_another_list_of_colors
    assert_backends_agree(recolored_program, frames: [3, 4])
  end

  def test_the_cartridge_shows_a_sprite_twice_its_size
    assert_backends_agree(changed_program { |gun| gun.scale(2.0) }, frames: 5)
  end

  def test_the_cartridge_shows_a_sprite_turned_on_a_tear_free_screen
    assert_backends_agree(changed_program(tear_free: true) { |gun| gun.face_angle(90) }, frames: [5, 6])
  end

  # A fade darkens the sprite with the picture, and moving the view over the picture leaves the
  # sprite where it is on the screen.
  def test_the_cartridge_fades_the_sprite_and_keeps_it_still_under_the_camera
    [false, true].each { |tear_free| assert_backends_agree(faded_under_camera(tear_free), frames: [4, 5]) }
  end

  private def faded_under_camera(tear_free)
    VBlank::Builder.new.tap do |builder|
      builder.instance_eval do
        tear_free ? screen(:bitmap, tear_free: true) : screen(:bitmap)
        image(:stripes, STRIPE_COLORS) { STRIPES }
        sprite :stripes, at: START, over_picture: true
        game_loop do
          clear_screen FIELD
          fill_rect 96, 56, 40, 40, :yellow
          fade :black, 50
          camera 12, 6
        end
      end
      builder.finalize_program
    end.program
  end

  # The bitmap screens keep their pictures in the first half of the sprites' memory, so on them
  # the sprites have 16K, not 32K: a sprite's pictures past that stop the build in plain words.
  def test_sprite_pictures_past_the_half_left_beside_a_bitmap_stop_the_build
    error = assert_raises(VBlank::BuildError) { assemble_rom(too_much_over_picture, name: "OVRFUL") }

    assert_match(/painted screen/i, error.message)
    assert_match(/16384/, error.message)
  end

  # Twelve 64x64 pictures, each different, at 2K each in sixteen colours: 24K, which a tiled
  # screen holds and a bitmap screen does not.
  private def too_much_over_picture
    VBlank::Builder.new.tap do |builder|
      builder.instance_eval do
        screen :bitmap
        palette = ("1".."9").to_a + ("a".."f").to_a
        12.times do |k|
          rows = Array.new(64) { |row| (0...64).map { |col| palette[((row * (k + 1)) + col) % 15] }.join }
          colors = palette.to_h { |ch| [ch, rgb(ch.to_i(16) + k, k, 31 - k)] }
          image(:"big#{k}", colors) { rows.join("\n") }
          sprite :"big#{k}", at: [k * 4, 0], over_picture: true
        end
        game_loop { clear_screen :black }
      end
      builder.finalize_program
    end.program
  end
end
