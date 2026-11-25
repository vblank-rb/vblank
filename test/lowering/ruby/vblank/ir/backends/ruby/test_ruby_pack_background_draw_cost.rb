# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_background_areas"

# What drawing a background read as the game starts costs the Ruby runtime a pass. Such a background
# keeps each tile of its slot once, as places, and each cell names its tile's bank and turn, applied
# as the cell is drawn (rg_tiled.rb). That is one more read a pixel than a tile kept in its colours,
# and nothing else: the row is still drawn a tile's row at a time, never through the routine that
# works out one pixel (rg_tile_pixel), and a pass makes no more objects than the same room built
# all-in-one, whose tiles are kept in their colours. Counted over passes that scroll the whole view,
# exact where a time is not; the picture is held to the interpreter by the pack parity tests.
class TestRubyPackBackgroundDrawCost < Minitest::Test
  include PackBackgroundAreaGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
  ALL_IN_ONE = VBlank::Cartridge::Options.new(for_computer: true)
  # A room of the slot of an original's size, more cells than a screen shows.
  ACROSS = 40
  DOWN = 30
  # A pass makes a few objects for the runtime's own bookkeeping, whichever way the tiles are kept.
  MOST_MORE_OBJECTS_A_PASS = 4
  # The most tiles a row of the screen crosses: thirty whole ones, and two cut at the edges by a scroll.
  TILES_A_SCREEN_ROW = (240 / 8) + 1

  # Objects made a pass, and over the passes the calls to draw one pixel, a row, and a tile's row of a
  # tile as drawn.
  Cost = Data.define(:objects, :pixel_calls, :row_calls, :drawn_calls)

  # What +passes+ more passes of the room scrolling cost, built as +options+ say.
  private def cost_of(options, passes)
    Dir.mktmpdir do |folder|
      areas = PackBackgroundAreaGames.world_areas(%i[field], ACROSS, DOWN, big: true)
      # The pack the all-in-one build makes is the file the build with it left out is handed.
      _, file = world_game_and_file(folder, areas, ACROSS, options: ALL_IN_ONE, scrolling: true)
      program, = world_game_and_file(folder, areas, ACROSS, options: options, scrolling: true)
      first = played(program, file, 2)
      last = played(program, file, 2 + passes)
      Cost.new(objects: (last.objects - first.objects) / passes, pixel_calls: last.pixel_calls - first.pixel_calls,
               row_calls: last.row_calls - first.row_calls, drawn_calls: last.drawn_calls - first.drawn_calls)
    end
  end

  # What playing +frames+ cost: the objects made, and the calls into the routines that draw a pixel
  # and a row of a background. Counting a call makes objects of its own, so the objects are counted
  # in a game whose calls are not.
  private def played(program, file, frames)
    calls = playing(program, file, frames, counted: true).call_counts
    Cost.new(objects: objects_playing(program, file, frames), pixel_calls: calls[:rg_tile_pixel], row_calls: calls[:rg_paint_map_row],
             drawn_calls: calls[:rg_paint_drawn_row])
  end

  private def objects_playing(program, file, frames)
    GC.start
    GC.disable
    objects = GC.stat(:total_allocated_objects)
    playing(program, file, frames)
    GC.stat(:total_allocated_objects) - objects
  ensure
    GC.enable
  end

  # The game, handed its pack, played +frames+; its calls counted where +counted+.
  private def playing(program, file, frames, counted: false)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    game.hand_file(file) if program.start_file
    game.count_calls(:rg_tile_pixel, :rg_paint_map_row, :rg_paint_drawn_row) if counted
    game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames, picture_and_sound: true))
    game
  end

  def test_a_room_read_at_start_draws_a_row_at_a_time_and_makes_no_more_objects_than_built_all_in_one
    all_in_one = cost_of(ALL_IN_ONE, 10)
    left_out = cost_of(LEFT_OUT, 10)

    assert_operator left_out.drawn_calls, :>, 0, "rows of tiles as drawn"
    assert_operator left_out.drawn_calls, :<=, left_out.row_calls * TILES_A_SCREEN_ROW, "a tile's row drawn at a time"
    assert_equal 0, left_out.pixel_calls, "pixels drawn one at a time"
    assert_equal all_in_one.row_calls, left_out.row_calls, "rows drawn"
    assert_operator left_out.objects, :<=, all_in_one.objects + MOST_MORE_OBJECTS_A_PASS,
                    "objects a pass: #{left_out.objects} read at start, #{all_in_one.objects} all-in-one"
  end
end
