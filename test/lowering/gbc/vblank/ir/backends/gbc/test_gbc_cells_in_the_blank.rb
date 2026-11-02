# frozen_string_literal: true

require "test_helper"

# A PASS THAT CHANGES MANY CELLS OF A BACKGROUND has them all written in the blank after it, so the
# game never waits for the display, and the blank has to hold them beside everything else it does:
# video memory takes no write once the display reads it again, so a cell the blank does not reach
# has to wait for the display, or it would be lost, and the interpreter's picture, held on every
# pass, would show it.
class TestGBCCellsInTheBlank < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # Cells on the top rows that land before the display reaches them. A pass keeps more than this
  # (CELLS_KEPT), for a bar low on the screen, where those land in time too.
  CELLS_A_BLANK_REACHES = 64

  def test_the_blank_holds_as_many_cells_as_a_pass_keeps_beside_every_sprite_moving
    kept = CELLS_A_BLANK_REACHES

    GBC::CheckedRun.new.run(cells_game(kept), frames: 12)
    pass
  end

  # A cell the pass changes, then more cells than a pass keeps, then that cell again: the last
  # change stands, and the first never comes back in the blank.
  def test_a_cell_changed_again_past_the_kept_cells_shows_the_last_change
    GBC::CheckedRun.new.run(cell_changed_twice_game(GBC::Runtime::Picture::CELLS_KEPT), frames: 12)
    pass
  end

  def test_a_cell_shown_now_past_the_kept_cells_shows_the_last_change
    GBC::CheckedRun.new.run(cell_changed_twice_game(GBC::Runtime::Picture::CELLS_KEPT, now: true), frames: 12)
    pass
  end

  def test_a_cell_changed_again_past_twice_the_kept_cells_shows_the_last_change
    GBC::CheckedRun.new.run(cell_changed_twice_game(GBC::Runtime::Picture::CELLS_KEPT * 2), frames: 12)
    pass
  end

  # The blank does more in a game with a bar, and much more with every sprite moving, so it can
  # end before the kept cells do. A cell it does not reach still goes in.
  def test_every_cell_kept_goes_in_when_the_blank_runs_out
    kept = CELLS_A_BLANK_REACHES

    GBC::CheckedRun.new.run(bar_cells_game(kept), frames: 12)
    pass
  end

  # Past what a blank reaches, a pass's cells all still show on one frame: a bar low on the screen
  # is whole, with no part of the pass a frame ahead of the rest.
  def test_a_pass_of_many_cells_on_a_low_bar_shows_whole_on_one_frame
    GBC::CheckedRun.new.run(bar_cells_game(120, top: 96), frames: 12)
    pass
  end

  private def bar_cells_game(cells, top: 0)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      board = status_bar :bar, tiles: :set, map: Array.new(18) { "#" * 20 }, top: top
      image(:dot, "#" => :white) { "##\n##" }
      dots = Array.new(40) { |i| sprite :dot, at: [(i % 8) * 8, 8 * (i / 8)] }
      turn = var :turn, 0
      game_loop do
        turn = 1 - turn
        dots.each { |dot| dot.x += 1 }
        if turn == 0
          cells.times { |i| board.set_tile i % 20, i / 20, "#" }
        else
          cells.times { |i| board.set_tile i % 20, i / 20, "." }
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def cell_changed_twice_game(others, now: false)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      passes = var :passes, 0
      game_loop do
        passes += 1
        if passes == 3
          field.set_tile 0, 0, "."
          others.times { |i| field.set_tile (i + 1) % 20, 1 + (i / 20), "." }
          field.set_tile 0, 0, "#", now: now
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def cells_game(cells)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      image(:dot, "#" => :white) { "##\n##" }
      dots = Array.new(40) { |i| sprite :dot, at: [(i % 8) * 8, 8 * (i / 8)] }
      turn = var :turn, 0
      game_loop do
        turn = 1 - turn
        dots.each { |dot| dot.x += 1 }
        field.scroll_by 1, 0
        if turn == 0
          cells.times { |i| field.set_tile i % 20, i / 20, "#" }
        else
          cells.times { |i| field.set_tile i % 20, i / 20, "." }
        end
      end
    end
    b.finalize_program
    b.program
  end
end
