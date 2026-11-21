# frozen_string_literal: true

require "test_helper"
require "place_games"

# How much work a game built as Ruby does to fill the faces of a place. A 3D place is filled a pixel
# at a time in Ruby, and a floor of a few hundred faces in view fills most of the lower half of the
# screen on every pass. What the runtime asks for each pixel of a face (where it lands, whether a fade
# or a mix or a kept picture changes it, which shade of colour it takes) is the whole cost of a pass,
# so the usual row, with none of those in force, is checked once and its pixels stored straight into
# the picture (rg_face_row). The picture is held to the interpreter's by the place tests this run
# plays; this is only the work.
#
# Counted, not timed. A time fails whenever other work shares the cores, so a pass of
# PlaceGames.big_floor is held to two counts that load cannot change. The objects it makes: each is
# one Ruby's garbage collector clears away later, and an array made for each pixel, as the fill once
# did, more than doubles them. And the pixels painted one at a time through rg_set_pixel: none, on a
# floor where nothing is in force, where a row not painted plain paints every pixel that way.
class TestRubyFaceFillPace < Minitest::Test
  # The most objects a pass of the big floor may make: a fifth over what a pass made where this was
  # written, about thirty for each face filled and none for a pixel. The floor paints more pixels a
  # pass than this, so one object made for each of them more than doubles it.
  MOST_OBJECTS_A_PASS = 13_000

  PASSES = 20

  private def play_frames(game, frames)
    game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames, picture_and_sound: true))
  end

  # The objects made over +frames+ frames of a fresh game of +program+, its calls not counted (the
  # wrapper that counts them makes objects of its own).
  private def objects_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    before = GC.stat(:total_allocated_objects)
    play_frames(game, frames)
    GC.stat(:total_allocated_objects) - before
  end

  # The pixel routines called over +frames+ frames of a fresh game of +program+.
  private def calls_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program).count_calls(:rg_set_pixel, :rg_screen_face)
    play_frames(game, frames)
    game.call_counts
  end

  # What PASSES more passes do, with what starting the game does taken away.
  private def work_of_passes(program)
    made = objects_playing(program, PASSES + 2) - objects_playing(program, 2)
    short = calls_playing(program, 2)
    [made, calls_playing(program, PASSES + 2).to_h { |name, count| [name, count - short[name]] }]
  end

  def test_a_pass_of_a_big_floor_makes_no_object_for_a_pixel_and_paints_every_row_plain
    made, calls = work_of_passes(PlaceGames.big_floor(perspective: :every_16_pixels))

    assert_operator calls[:rg_screen_face], :>, 100 * PASSES, "the floor fills its faces on every pass"
    assert_operator made / PASSES, :<=, MOST_OBJECTS_A_PASS, "objects made a pass"
    assert_equal 0, calls[:rg_set_pixel], "pixels of the floor painted one at a time, not by a row painted plain"
  end

  # The count is kept only for a game that asks: one that does not has nothing wrapped round its
  # routines, and a real game is never asked.
  def test_a_game_not_asked_counts_nothing
    assert_nil VBlank::IR::Backends::Ruby.new.live_game(PlaceGames.big_floor).call_counts
  end
end
