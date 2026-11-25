# frozen_string_literal: true

require "test_helper"
require "stringio"

# A background cell changed at a place written in the program, on the Color. A game's lights and
# arrows are many such cells in one frame, so working each one's place out as the game runs is what
# made a busy frame run over. The place is known as the cartridge is built, and a cell off the map
# still changes nothing.
class TestGBCCellPlaces < Minitest::Test
  CELLS = 24

  # A game changing CELLS cells a pass. +worked_out+ keeps their columns in a variable, so the
  # cartridge cannot know them; otherwise they are written in the program. The variable can hold
  # more than a byte (300 while A is held, which nothing holds here), since a column the build
  # proves stays in a byte has a quicker way of its own (GBC Picture#byte_column?), and this is the
  # whole number worked out as the game runs.
  private def busy_game(worked_out:)
    VBlank.game("CELLS #{worked_out}", consoles: %i[gba gbc]) do
      screen :tiled
      image(:light, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:dark, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :light, "." => :dark
      room = background :room, tiles: :set, map: ["#" * 32] * 18
      first = 0
      game_loop do
        first = 0
        first = 300 if held(:a)
        CELLS.times { |n| worked_out ? room.set_tile(first + n, 2, ".") : room.set_tile(n, 2, ".") }
      end
    end
  end

  private def idle_share(game)
    game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 30).idle_share
  end

  def test_cells_at_written_places_cost_less_than_cells_worked_out
    assert_operator idle_share(busy_game(worked_out: false)), :>, idle_share(busy_game(worked_out: true)) + 0.04
  end

  # The corners of the map and past each edge, every one checked against the interpreter.
  def test_cells_at_written_places_land_where_the_interpreter_puts_them
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:light, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:dark, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :light, "." => :dark
      room = background :room, tiles: :set, map: ["#" * 20] * 18
      room.set_tile 0, 0, "."
      room.set_tile 19, 0, "."
      room.set_tile 0, 17, "."
      room.set_tile 19, 17, "."
      room.set_tile 20, 3, "."
      room.set_tile 3, 18, "."
      room.set_tile(-1, 4, ".")
      room.set_tile 4, -1, "."
      game_loop { wait_vblank }
    end
    b.finalize_program

    game_player.run(b.program, frames: 3)
  end

  def test_a_status_bar_cell_at_a_written_place_lands_where_the_interpreter_puts_it
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:light, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:dark, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :light, "." => :dark
      background :room, tiles: :set, map: ["#" * 32] * 18
      bar = status_bar :bar, tiles: :set, map: ["#" * 20] * 2, top: 16
      bar.set_tile 4, 1, "."
      game_loop { wait_vblank }
    end
    b.finalize_program

    game_player.run(b.program, frames: 3)
  end
end
