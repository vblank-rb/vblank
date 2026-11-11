# frozen_string_literal: true

require "test_helper"
require "stringio"
require "place_games"

# What the PlayStation spends drawing a place of about a thousand faces every pass, measured in Beetle
# PSX (Diagnostics::PS1Profiler): the floor of PlaceGames.big_floor, about half of it behind the viewer
# or beside the view and most of the rest far off and a few pixels big, as a level read from a file is.
# The console's own games sent such a face to the graphics chip as it was, the chip's drawing area
# holding it to the screen; so does this build (Runtime::Faces, a face sent straight from its corners).
class TestPS1PlaceFloorPace < Minitest::Test
  # The floor as a game for the PlayStation, drawn in perspective +perspective+.
  def self.floor_game(perspective)
    level = PlaceGames.big_floor_data
    VBlank.game("FLOOR PACE", consoles: %i[ps1]) do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: PlaceGames::TILE
      place :floor, **level
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :floor, seen_by: eye, perspective: perspective
      end
    end
  end

  # The most frames a pass takes in each perspective. Without perspective it is the floor of the place
  # cost tests (test/lowering/gba/vblank/ir/test_place_geometry_cost.rb). In perspective every face
  # costs a divide's worth more at each corner, and the near faces are cut into squares.
  #
  # In perspective the processor is at work for nearly all of its four frames, so a change that costs
  # the floor a few thousand cycles a pass takes it to five: the profile's lines for the runtime and
  # for the face statements say where they went.
  MOST_FRAMES = { none: 3, every_8_pixels: 4 }.freeze

  GAMES = MOST_FRAMES.keys.to_h { |perspective| [perspective, floor_game(perspective)] }

  MOST_FRAMES.each do |perspective, most|
    define_method(:"test_the_floor_in_perspective_#{perspective}_takes_#{most}_frames_a_pass_or_fewer") do
      result = profile(GAMES.fetch(perspective))
      frames = result.frames.fdiv(result.passes)

      assert_operator frames, :<=, most, "the floor in perspective #{perspective} took #{frames} frames a pass"
    end

    # The floor drawn for the PlayStation, its faces drawn whole, cut at the near limit, clipped at the
    # screen's edges and cut into squares, is the picture the chip's rules make of the triangles sent
    # (PS1::CheckedRun), and the game's numbers are the interpreter's.
    define_method(:"test_the_floor_in_perspective_#{perspective}_is_drawn_as_the_chip_draws_it") do
      played = game_player.run(GAMES.fetch(perspective).program(console: :ps1), frames: 3)

      refute_equal VBlank::Testing.shown(:black), played.screen.pixel(160, 230), "the floor below the viewer is drawn"
    end
  end

  private def profile(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 24)
  end
end
