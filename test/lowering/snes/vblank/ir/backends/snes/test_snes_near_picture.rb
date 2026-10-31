# frozen_string_literal: true

require "test_helper"

# How a checked run holds the picture of a game with a see-through layer: the console rounds a mix a
# step from the interpreter, and only a mix.
class TestSNESNearPicture < Minitest::Test
  NearPicture = VBlank::IR::Backends::SNES::HeadlessRun::NearPicture

  RED_30 = 30
  RED_31 = 31

  def test_a_mixed_pixel_a_step_out_is_the_same_picture
    assert_equal NearPicture.of([RED_30, 0], [1, 0]), NearPicture.of([RED_31, 0])
  end

  def test_a_pixel_nothing_mixed_a_step_out_is_a_different_picture
    refute_equal NearPicture.of([0, RED_30], [1, 0]), NearPicture.of([0, RED_31])
  end

  def test_a_mixed_pixel_two_steps_out_is_a_different_picture
    refute_equal NearPicture.of([29, 0], [1, 0]), NearPicture.of([RED_31, 0])
  end

  def test_pictures_that_are_equal_hash_alike
    interpreter = NearPicture.of([RED_30], [1])
    cartridge = NearPicture.of([RED_31])

    assert_equal interpreter.hash, cartridge.hash
    assert interpreter.eql?(cartridge)
    assert_equal 1, [interpreter, cartridge].uniq.length
  end

  def test_two_cartridge_pictures_are_held_exactly
    refute_equal NearPicture.of([RED_30]), NearPicture.of([RED_31])
  end
end
