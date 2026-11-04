# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/vblank/builder/test_places_on_the_advance"
require VBlank.root.join("examples/raycaster").to_s
require VBlank.root.join("examples/breakout").to_s

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

  def test_a_face_cut_at_the_near_limit_agrees
    assert_backends_agree(PlaceGames.floor, frames: 3, console_frames: 30, name: "FLOOR")
  end

  def test_a_face_seen_from_behind_agrees_with_and_without_both_sides
    assert_backends_agree(PlaceGames.square(turned_round: true), frames: 3, console_frames: 30, name: "BACK")
    assert_backends_agree(PlaceGames.square(turned_round: true, both_sides: true), frames: 3, console_frames: 30,
                                                                                    name: "BOTH")
  end

  # The edges nothing outside is drawn and the picture are worked out as the game runs, so each
  # frame compared is a different face: every eight passes a new one.
  def test_a_face_whose_edges_and_picture_change_agrees_at_each_change
    assert_backends_agree(PlaceGames.moving_five_corners(passes: 8), frames: [6, 14, 22, 30], name: "MOVING")
  end

  # A game that draws no place carries none of the machinery: no routine for filling a face in
  # the quick memory, so its layout and its bytes are what they were before places existed.
  def test_a_game_with_no_place_carries_nothing_of_one
    [Raycaster, Breakout].each do |game|
      backend = GBA.new
      backend.lower(game.program)

      refute_includes backend.routine_addresses.keys, VBlank::IR::Backends::GBA::Faces::ROUTINE, game.name
    end
  end
end
