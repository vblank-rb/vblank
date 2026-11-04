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

  def test_listed_faces_held_to_a_window_agree
    assert_backends_agree(PlaceGames.listed_faces([1, 0]), frames: 3, console_frames: 30, name: "LISTED")
    assert_backends_agree(PlaceGames.listed_faces([0, 7, 1], window: [100, 40, 140, 120]), frames: 3,
                                                                                          console_frames: 30, name: "WINDOW")
  end

  # A row starting on the right half of a pair and ending on the left half of one: the pixels
  # written alone, beside the ones written in pairs.
  def test_rows_starting_and_ending_halfway_through_a_pair_agree
    [[101, 40, 139, 120], [101, 40, 140, 120], [100, 40, 139, 120], [101, 40, 104, 120], [101, 40, 102, 120]]
      .each do |window|
        assert_backends_agree(PlaceGames.listed_faces([0], window: window), frames: 3, console_frames: 30, name: "ODD")
      end
  end

  def test_a_wall_leaning_away_agrees_in_each_perspective
    %i[none every_8_pixels every_pixel].each do |perspective|
      assert_backends_agree(PlaceGames.wall_down_the_side(perspective), frames: 3, console_frames: 30, name: "WALL")
    end
  end

  def test_screen_spots_agree
    spots = [[-1.0, 1.0, 2.0], [1.0, -1.0, 2.0], [0.11, 0.0, 2.0], [0.0, 0.0, -1.0], [3.0, -2.5, 1.5]]
    program = PlaceGames.screen_spots(spots)
    rom = assemble_rom(program)
    played = Reference.new.run(program, frames: 3)

    cartridge = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)

    5.times do |k|
      %i[x y behind].each do |part|
        assert_equal played[:"#{part}#{k}"], cartridge.var(:"#{part}#{k}"), "#{part}#{k}"
      end
    end
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
