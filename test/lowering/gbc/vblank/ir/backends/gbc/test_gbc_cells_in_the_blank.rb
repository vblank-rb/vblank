# frozen_string_literal: true

require "test_helper"
require "stringio"

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

  # ...and with no frame held for it: the cells the blank does not reach are on lines the display has
  # not drawn yet, so they go in while it draws, and putting the pass up never runs past the blank
  # (a frame held by :gap, Diagnostics::TapeProfile).
  def test_a_pass_of_many_cells_on_a_low_bar_holds_no_frame_for_its_cells
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(bar_cells_game(120, top: 96), title: "CELLS")
    result = rom.profile(out: StringIO.new, tape: NOTHING_PRESSED, frames: 4..30)

    assert_empty result.held.select { |reading| reading.picture_held_by == :gap }.map(&:frame)
  end

  # A WHOLE SCREEN OF CELLS CHANGED IN ONE PASS, 20 by 18, is more than one blank can write and more
  # than the first list holds. It is spread over the blanks after the pass, as the console's own games
  # bring a screen in: a bounded number of cells each blank, the processor asleep between them (Pan
  # Docs, "Accessing VRAM and OAM": video memory takes writes only while the display is not reading
  # it). The pass itself does only the queueing.
  SCREEN_CELLS = 20 * 18

  def test_a_screen_of_cells_changed_in_one_pass_shows_whole
    GBC::CheckedRun.new.run(screen_change_game, frames: 24)
    pass
  end

  # Before the cells past the first list were kept for the blanks, the pass that changes the screen
  # was awake for the whole of its frame and three quarters of the next, waiting on the display to
  # write cells between its lines. Now the pass only queues them: about 45 instruction cycles a cell
  # into the first list and 65 into the far one, with the game's own call to each, which is most of
  # a frame for a whole screen. The budget is that, with room for the blank's other copies.
  MOST_AWAKE_SHARE = 0.85

  def test_a_screen_of_cells_changed_in_one_pass_holds_no_frame_awake
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(screen_change_game, title: "CELLS")
    result = rom.profile(out: StringIO.new, tape: NOTHING_PRESSED, frames: 4..30)

    busiest = result.readings.max_by(&:awake_share)
    assert_operator busiest.awake_share, :<=, MOST_AWAKE_SHARE, "frame #{busiest.frame} was awake for #{busiest.awake_share.round(3)}"
  end

  # A bar shown with another map takes the bar's cells changed before it out of both lists, and
  # moves the background's cells kept past the first list into the room left, so the cells changed
  # after it go after them.
  def test_a_bar_map_shown_after_more_cells_than_the_first_list_holds_keeps_the_rest
    GBC::CheckedRun.new.run(bar_map_over_many_cells_game, frames: 24)
    pass
  end

  NOTHING_PRESSED = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: CELLS 0x00000000
    starts from: power-on
  TAPE

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

  # Every cell of the screen changed one pass in four, the other way four passes later.
  private def screen_change_game
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
        if (passes & 7) == 4
          SCREEN_CELLS.times { |i| field.set_tile i % 20, i / 20, "." }
        elsif (passes & 7) == 0
          SCREEN_CELLS.times { |i| field.set_tile i % 20, i / 20, "#" }
        end
      end
    end
    b.finalize_program
    b.program
  end

  # On pass 3: a hundred changes of the bar's cells and a hundred of the background's, the bar's
  # other map shown, then five of the bar's and seventy of the background's.
  private def bar_map_over_many_cells_game
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      image(:green_art, "#" => :green) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art, "g" => :green_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      board = status_bar :bar, tiles: :set, map: { plain: Array.new(4) { "#" * 20 }, other: Array.new(4) { "." * 20 } },
                               top: 128
      passes = var :passes, 0
      game_loop do
        passes += 1
        if passes == 3
          100.times { |i| board.set_tile i % 20, (i / 20) % 4, "g" }
          100.times { |i| field.set_tile i % 20, i / 20, "." }
          board.show_map :other
          5.times { |i| board.set_tile i, 1, "g" }
          70.times { |i| field.set_tile i % 20, 3 + (i / 20), "g" }
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
