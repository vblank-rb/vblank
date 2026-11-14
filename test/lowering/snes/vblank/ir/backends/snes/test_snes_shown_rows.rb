# frozen_string_literal: true

require "test_helper"

# WHAT A PICTURE THAT STOPS EARLY GAINS A SUPER NINTENDO CARTRIDGE (`screen :bitmap, shown_rows:`).
# Video memory takes writes only while the console is not drawing, so the rows given up, with the
# screen off there, are time to copy in as well as the blank's (Runtime::Letterbox). What is
# measured is the copy itself: a game repaints the whole screen in another colour every pass, too
# much for one blank, and the video memory read after every frame says how many of the screen's
# tiles arrived in that frame. Each frame of the copy has one blank, and the rows given up round
# it, so the most a frame took is what one of them holds. VBLANK_SHOWN_ROWS_BYTES=1 prints it.
class TestSNESShownRows < Minitest::Test
  # The screen's tiles in video memory, 896 of 64 bytes (Runtime::Paint).
  TILE_BYTES = 64
  TILES = 896

  private def repainting_game(rows)
    VBlank.game("REPAINT", consoles: %i[snes]) do
      if rows
        screen :bitmap, shown_rows: rows
      else
        screen :bitmap
      end
      step = var :step, 0
      game_loop do
        step += 1
        if step % 2 == 1
          fill_rect 0, 0, 256, 224, :red
        else
          fill_rect 0, 0, 256, 224, :blue
        end
      end
    end
  end

  # The most bytes of the screen's tiles that arrived in one frame, in whole tiles: a tile counts
  # once any of its bytes changed.
  private def most_bytes_a_frame(rows)
    reader = VBlank::Diagnostics::Verifier.new(repainting_game(rows).build_rom(console: :snes), frames: 30)
    before = reader.video_ram.byteslice(0, TILES * TILE_BYTES)
    most = 0
    120.times do
      reader.step
      now = reader.video_ram.byteslice(0, TILES * TILE_BYTES)
      changed = (0...TILES).count { |tile| now.byteslice(tile * TILE_BYTES, TILE_BYTES) != before.byteslice(tile * TILE_BYTES, TILE_BYTES) }
      most = [most, changed * TILE_BYTES].max
      before = now
    end
    most
  end

  # The blank alone, and the blank with 32 rows given up at the top and 32 at the bottom.
  def test_rows_given_up_hold_more_of_the_copy_than_the_blank_alone
    blank = most_bytes_a_frame(nil)
    shortened = most_bytes_a_frame(32...192)
    warn "one blank: #{blank} bytes; with 64 rows given up: #{shortened} bytes" if ENV["VBLANK_SHOWN_ROWS_BYTES"]

    assert_operator blank, :<=, 6_144, "a blank alone holds what Runtime::Blank counts"
    assert_operator shortened, :>=, blank * 2, "64 rows given up more than double what a frame copies"
  end

  # A picture that stops early writes the screen's registers a line at a time as it is drawn
  # (HDMA), so a big fill on it is stored by the processor and not copied by the copying engine:
  # on the console's first processor the two can lock it up (Runtime::Paint#fill_tiles_by_dma?).
  # Its pictures are still the interpreter's.
  def test_a_big_fill_on_a_picture_that_stops_early_is_stored_and_shows_as_the_interpreter
    game = VBlank.game("HALF", consoles: %i[snes]) do
      screen :bitmap, shown_rows: 32...192
      n = var :n, 0
      game_loop do
        clear_screen :black
        fill_rect 4, 36, 8, 8, :white
        fill_rect 0, 32, 128, 160, :red if n >= 3
        n += 1
      end
    end
    VBlank::IR::Backends::SNES::CheckedRun.new.run(game.program(console: :snes), frames: 8) # raises if a pass differs
    labels = game.build_rom(console: :snes).built.code.keys.map(&:to_s)

    assert_includes labels, "rt_paint_fill_band_stored"
    refute_includes labels, "rt_paint_fill_band_copied"
  end

  # Every row shown is the screen as it is: the same cartridge as a game that names none.
  def test_every_row_shown_builds_the_same_cartridge
    assert_equal repainting_game(nil).build_rom(console: :snes).bytes, repainting_game(0...224).build_rom(console: :snes).bytes
  end

  # A picture of 160 rows, 128x80 shown doubled, gives up the rest, and a frame's copy then holds
  # more than the 10240 bytes of such a picture at a byte a pixel.
  def test_a_picture_of_160_rows_copies_a_128_by_80_picture_in_a_frame
    shortened = most_bytes_a_frame(32...192)

    assert_operator shortened, :>=, 128 * 80, "a frame of 64 rows given up holds a 128x80 picture"
  end
end
