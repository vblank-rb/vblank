# frozen_string_literal: true

require "test_helper"
require "stringio"

# How many background cells a pass can change on the Color and still show them on the next
# frame. The cells are written in the blank after the pass (Runtime::Picture, rt_picture_cells),
# and what the blank does not reach waits for the blank after, so a pass that changes more shows a
# frame late and the game runs at half speed.
#
# The budget, from Pan Docs ("LCD Status", "CGB Registers"): the blank is ten lines of 456 dots,
# 2280 instruction cycles at the double speed the game runs at, and video memory is open all
# through it. Written one at a time, a cell cost 35 cycles, and a pass of 60 showed a frame late.
# Written four at a time with one look at the line and one bank switch a cell
# (Runtime::Picture#emit_cells_in_fours), it costs about 25; this pins a whole number of groups a
# little under what the blank then holds beside its other copies, so a few cycles more elsewhere in
# the blank do not flip it.
class TestGBCCellsPerBlank < Minitest::Test
  CELLS_SHOWN_NEXT_FRAME = 84
  FULL_SPEED = 59.0

  # A game whose every pass gives +count+ cells the other of two tiles, along rows of 20. With
  # +twice+ the first cell is written again at the end of the pass, with the tile it had before,
  # so the last write must win.
  private def cells_game(count, twice: false)
    VBlank.game("CELLS #{count}#{' TWICE' if twice}", consoles: %i[gbc]) do
      screen :tiled
      image(:dark, "#" => :blue, "." => :black) { (["##..##.."] * 8).join("\n") }
      image(:light, "#" => :yellow, "." => :red) { (["#..##..#"] * 8).join("\n") }
      tiles :set, "a" => :dark, "b" => :light
      world = background :world, tiles: :set, map: Array.new(32) { "a" * 32 }
      phase = var :phase, 0
      game_loop do
        count.times { |n| world.set_tile n % 20, n / 20, phase }
        world.set_tile 0, 0, 1 - phase if twice
        phase.store!(1 - phase)
      end
    end
  end

  private def fps(count)
    rom = cells_game(count).build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 60).fps
  end

  def test_a_pass_changing_many_cells_shows_them_on_the_next_frame
    shown = fps(CELLS_SHOWN_NEXT_FRAME)

    assert_operator shown, :>=, FULL_SPEED,
                    "a pass changing #{CELLS_SHOWN_NEXT_FRAME} cells runs at #{shown.round(1)} frames a second"
  end

  # The cells written four at a time and one at a time show what the interpreter shows, pass for
  # pass: a count that is a whole number of groups, one with cells left over, and one more than
  # the blank holds, whose rest wait for the blank after.
  def test_cells_written_in_groups_show_as_the_interpreter_shows
    [8, 7, CELLS_SHOWN_NEXT_FRAME + 2, 120].each do |count|
      game_player.run(cells_game(count).program, frames: 8)
    end
  end

  def test_a_cell_written_twice_in_a_pass_ends_with_its_last_tile
    game_player.run(cells_game(9, twice: true).program, frames: 8)
  end
end
