# frozen_string_literal: true

require "test_helper"
require "differential"
require "place_games"
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

  # A place declared from data is the place the calls make, so its cartridge is the same bytes.
  def test_a_place_declared_by_data_builds_the_same_cartridge_as_one_declared_by_calls
    by_data = assemble_rom(PlaceGames.declared_by_data(data: true)).buffer
    by_calls = assemble_rom(PlaceGames.declared_by_data(data: false)).buffer

    assert_equal by_calls, by_data
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

  include PlaceGames::WindowHugging

  # The cartridge's fill passes over a face wholly outside its window itself
  # (Backends::GBA::Faces#emit_skip_face_outside_edges), on the corners the near limit cut it to.
  # Through windows hugging the square face and a wall the near limit cuts, it draws what the
  # interpreter draws.
  def test_faces_through_windows_hugging_them_agree
    %i[square side].each do |shape|
      windows_hugging_face(shape, spin: 0.3, rise: 0.013).each do |window|
        assert_backends_agree(PlaceGames.face_through_windows(shape, spin: 0.3, rise: 0.013, windows: [window]),
                              frames: 3, console_frames: 30, name: "HUG")
      end
    end
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

  SEE_THROUGH_OR_NOT = [false, true].freeze

  # A face lit from its corners: each pixel the shading's colour for its blended light, leaning
  # away in each perspective, with see-through pixels, and with light the game adds as it runs.
  def test_a_lit_face_agrees_in_each_perspective
    %i[none every_8_pixels every_pixel].each do |perspective|
      SEE_THROUGH_OR_NOT.each do |see_through|
        program = PlaceGames.lit_square(left: 0.1, right: 0.95, perspective: perspective, see_through: see_through,
                                        far: 3.0)
        assert_backends_agree(program, frames: 3, console_frames: 30, name: "LIT")
      end
    end
    assert_backends_agree(PlaceGames.lit_square(left: 0.0, right: 0.3, added: 0.5), frames: 3, console_frames: 30,
                                                                                      name: "LAMP")
  end

  # A shading may list a colour the screen shows for something else (here black, cleared to) and
  # give it, at a level, a colour no lit picture can come to (navy). Nothing lit is ever black, so
  # the screen never needs navy: the cartridge builds, and draws as the interpreter does.
  def test_a_shading_listing_a_colour_only_the_clear_screen_uses_builds_and_agrees
    assert_backends_agree(shading_listing_black, frames: 3, console_frames: 30, name: "LITBLACK")
  end

  private def shading_listing_black
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :white, width: 8, height: 8, data: [0x7FFF] * 64
      shading :dark, colors: [0x7FFF, 0x0000, 0x5000], levels: [[1, 2, 2], [0, 1, 2]]
      place :wall, shading: :dark do
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
             picture: :white, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]], light: [0.0, 1.0, 1.0, 0.0]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :wall, seen_by: eye, perspective: :none
      end
    end
    builder.finalize_program
    builder.program
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
    assert_backends_agree(PlaceGames.moving_five_corners(passes: 8, lit: true), frames: [6, 14, 22, 30],
                          name: "MOVINGLIT")
  end

  # The door's slot pointed at the next picture every eight passes, so each frame compared is in the
  # middle of a different picture: red, green, blue, then a number passed over.
  def test_a_slot_pointed_at_another_picture_agrees_at_each_change
    assert_backends_agree(PlaceGames.changing_door(passes: 8), frames: [6, 14, 22, 30], name: "DOOR")
  end

  # A viewer turned by angles the game works out (PlaceGames::SPINS), a turn every eight passes,
  # so each frame compared is in the middle of a different turn's view.
  def test_a_viewer_turned_by_a_worked_out_angle_agrees_at_each_turn
    assert_backends_agree(PlaceGames.turning_square(passes: 8), frames: [6, 14, 22, 30, 38, 46], name: "TURNING")
    assert_backends_agree(PlaceGames.turning_square(passes: 8, whole: true), frames: [6, 14, 22, 30, 38, 46],
                          name: "WHOLETURN")
  end

  # One shape drawn at two positions and facings the game works out, each changing every eight
  # passes, so each frame compared is in the middle of a different pair of stances.
  def test_one_shape_drawn_at_two_moving_stances_agrees_at_each_change
    assert_backends_agree(PlaceGames.moved_shapes(passes: 8), frames: [6, 14, 22, 30, 38], name: "ROBOTS")
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
