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
    %i[none every_16_pixels every_8_pixels every_pixel].each do |perspective|
      assert_backends_agree(PlaceGames.wall_down_the_side(perspective), frames: 3, console_frames: 30, name: "WALL")
      assert_backends_agree(PlaceGames.striped_wall(perspective), frames: 3, console_frames: 30, name: "STRIPES")
    end
    # A game drawing every 8 pixels and every 16 has a run of whole stretches for each.
    assert_backends_agree(PlaceGames.striped_wall(%i[every_8_pixels every_16_pixels]), frames: 3, console_frames: 30,
                                                                                         name: "BOTHRUNS")
  end

  # ...and with see-through pixels, which in perspective take runs of whole stretches of their own
  # (GBA::Faces.see_through_runs): bars and gaps crowded into one pair at the wall's far end, and
  # stripes a picture pixel wide.
  def test_a_see_through_wall_leaning_away_agrees_in_each_perspective
    %i[none every_16_pixels every_8_pixels every_pixel].each do |perspective|
      assert_backends_agree(PlaceGames.wall_down_the_side(perspective, see_through: true), frames: 3, console_frames: 30,
                                                                                           name: "GRATE")
      assert_backends_agree(PlaceGames.striped_wall(perspective, see_through: true), frames: 3, console_frames: 30,
                                                                                    name: "GAPS")
    end
    both = PlaceGames.striped_wall(%i[every_8_pixels every_16_pixels], see_through: true)
    assert_backends_agree(both, frames: 3, console_frames: 30, name: "BOTHGAPS")
  end

  # THE BIGGEST FILL ROUTINE THERE IS: lit, see-through, every 8 pixels and every 16 in one game, so
  # it has every run and every twin. Its room in the quick memory (GBA::Faces.routine_bytes) leaves
  # it little to spare, so a routine grown past it fails here, not in a game.
  def test_a_lit_see_through_face_drawn_every_8_and_every_16_pixels_builds_and_agrees
    program = PlaceGames.lit_square(left: 0.1, right: 0.95, perspective: %i[every_8_pixels every_16_pixels],
                                    see_through: true, far: 3.0)

    assert_equal [8, 16], VBlank::IR::Backends::GBA::Faces.see_through_runs(program)
    assert_backends_agree(program, frames: 3, console_frames: 30, name: "LITBOTH")
  end

  # A see-through face held to windows that cut its rows short at either end, so a run of whole
  # stretches hands a row's last stretch back to be drawn a stretch at a time, a pixel kept back.
  def test_a_see_through_face_through_windows_agrees
    %i[square side].product([[0, 0, 150, 160], [61, 0, 240, 160], [73, 20, 141, 131]]).each do |shape, window|
      program = PlaceGames.face_through_windows(shape, spin: 0.3, rise: 0.013, windows: [window], see_through: true)
      assert_backends_agree(program, frames: 3, console_frames: 30, name: "GRATEWIN")
    end
  end

  SEE_THROUGH_OR_NOT = [false, true].freeze

  # A face lit from its corners: each pixel the shading's colour for its blended light, leaning
  # away in each perspective, with see-through pixels, and with light the game adds as it runs.
  def test_a_lit_face_agrees_in_each_perspective
    %i[none every_16_pixels every_8_pixels every_pixel].each do |perspective|
      SEE_THROUGH_OR_NOT.each do |see_through|
        program = PlaceGames.lit_square(left: 0.1, right: 0.95, perspective: perspective, see_through: see_through,
                                        far: 3.0)
        assert_backends_agree(program, frames: 3, console_frames: 30, name: "LIT")
      end
    end
    assert_backends_agree(PlaceGames.lit_square(left: 0.0, right: 0.3, added: 0.5), frames: 3, console_frames: 30,
                                                                                      name: "LAMP")
  end

  # A picture given as numbers into its shading's colours, two of them the same white that darken
  # apart: the cartridge gives each its own number on the screen, from its own palette or from the
  # one the game gives (which holds that white twice), and draws as the interpreter does.
  def test_two_equal_colours_given_as_numbers_agree
    [nil, [0x0000, 0x7FFF, 0x2108, 0x7FFF]].each do |screen_colors|
      [0.0, [0.0, 1.0, 1.0, 0.0]].each do |light|
        assert_backends_agree(PlaceGames.twin_whites(light: light, screen_colors: screen_colors), frames: 3,
                                                                                                  console_frames: 30, name: "TWINS")
      end
    end
  end

  # The screen's own list holds that white once, so it has no second number to keep the two apart.
  def test_a_screen_list_without_a_second_white_is_a_friendly_error
    program = PlaceGames.twin_whites(light: 0.0, screen_colors: [0x0000, 0x7FFF, 0x2108])
    error = assert_raises(VBlank::IR::Palette::Missing) { assemble_rom(program) }

    assert_match(/place 1/, error.message)
    assert_match(/again/, error.message)
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

  # Ten places and thirty, each a routine with words of its own: every square on the cartridge
  # where the interpreter draws it.
  def test_many_places_agree
    assert_backends_agree(PlaceGames.many_places(10), frames: 3, console_frames: 30, name: "TENPLACES")
    assert_backends_agree(PlaceGames.many_places(30), frames: 3, console_frames: 30, name: "THIRTYPLACES")
  end

  # The routine that fills a face is one for the whole game, and every word it reads is named
  # before the places' own (GBA::Faces.words), so it is the same size however many places there are.
  def test_the_fill_routine_is_the_same_size_for_one_place_or_thirty
    sizes = [1, 10, 30].map { |count| fill_routine_bytes(PlaceGames.many_places(count)) }

    assert_equal [sizes.first] * 3, sizes
  end

  # The runs for see-through pictures in perspective are in the routine only for a game that fills
  # a face in perspective with one: the same wall solid, or see-through without perspective, keeps
  # the routine it had.
  def test_only_a_see_through_picture_in_perspective_grows_the_fill_routine
    solid = fill_routine_bytes(PlaceGames.striped_wall(:every_16_pixels))
    flat = fill_routine_bytes(PlaceGames.striped_wall(:none, see_through: true))

    assert_operator fill_routine_bytes(PlaceGames.striped_wall(:every_16_pixels, see_through: true)), :>, solid
    assert_equal fill_routine_bytes(PlaceGames.striped_wall(:none)), flat
  end

  # ...and only for the settings the see-through picture is drawn with: a grate drawn without
  # perspective beside a solid wall drawn every 16 pixels has no twin, one drawn every 16 has that
  # setting's alone.
  def test_the_see_through_twins_follow_the_settings_the_see_through_picture_is_drawn_with
    faces = VBlank::IR::Backends::GBA::Faces

    assert_empty faces.see_through_runs(grate_beside_wall(grate: :none, wall: :every_16_pixels))
    assert_equal [16], faces.see_through_runs(grate_beside_wall(grate: :every_16_pixels, wall: :every_8_pixels))
    assert_equal [8, 16], faces.see_through_runs(PlaceGames.striped_wall(%i[every_8_pixels every_16_pixels], see_through: true))
    assert_backends_agree(grate_beside_wall(grate: :every_8_pixels, wall: :every_16_pixels), frames: 3, console_frames: 30,
                                                                                            name: "BESIDE")
  end

  # A see-through wall drawn with +grate+ and a solid one drawn with +wall+, the same pass.
  private def grate_beside_wall(grate:, wall:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :solid, width: 8, height: 8, data: [0x001F] * 64
      image :gaps, width: 8, height: 8, data: [0x001F, PlaceGames::SEE_THROUGH] * 32, transparent: PlaceGames::SEE_THROUGH
      { grate: :gaps, wall: :solid }.each do |name, picture|
        place name do
          face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 3.0), point(1.0, -1.0, 3.0), point(-1.0, -1.0, 2.0),
               picture: picture, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
        end
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        draw_place :grate, seen_by: eye, perspective: grate
        draw_place :wall, seen_by: eye, perspective: wall
      end
    end
    b.finalize_program
    b.program
  end

  private def fill_routine_bytes(program)
    backend = GBA.new
    backend.lower(program)
    backend.routine_addresses.fetch(VBlank::IR::Backends::GBA::Faces::ROUTINE).size
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
