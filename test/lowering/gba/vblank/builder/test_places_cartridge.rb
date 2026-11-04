# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/vblank/builder/test_places_on_the_advance"

# A place made of flat faces on the Advance's cartridge, read back in the emulator: every pixel
# where the interpreter puts it. What the faces draw is in
# test/console/gba/vblank/builder/test_places_on_the_advance.rb.
class TestPlacesCartridge < Minitest::Test
  include Differential

  def test_a_square_face_lands_on_the_cartridge_where_it_lands_on_the_interpreter
    assert_backends_agree(PlaceGames.square, frames: 3, console_frames: 30, name: "FACE")
  end

  def test_a_picture_repeats_on_the_cartridge_as_on_the_interpreter
    on_picture = [[-70, -70], [140, -70], [140, 140], [-70, 140]]
    assert_backends_agree(PlaceGames.square(on_picture: on_picture), frames: 3, console_frames: 30, name: "REPEAT")
  end

  def test_a_face_wider_than_the_screen_is_cut_on_the_cartridge_as_on_the_interpreter
    assert_backends_agree(PlaceGames.square(x_scale: 3.0), frames: 3, console_frames: 30, name: "WIDE")
  end

  def test_two_faces_with_their_own_pictures_agree
    assert_backends_agree(PlaceGames.two_faces, frames: 3, console_frames: 30, name: "PAIR")
  end
end
