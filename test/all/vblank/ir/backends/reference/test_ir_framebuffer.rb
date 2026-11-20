# frozen_string_literal: true

require "test_helper"

# The simulated framebuffer in isolation — a plain 2D grid of colors the reference
# backend draws into. No IR, no interpreter here: just the screen model and its
# edge-clipping promise.
class TestIRFramebuffer < Minitest::Test
  Framebuffer = VBlank::IR::Backends::Reference::Framebuffer

  # The Advance's screen, which most of these draw on.
  private def advance_screen(fill: 0) = Framebuffer.new(width: 240, height: 160, fill: fill)

  def test_set_pixel_round_trips
    fb = advance_screen
    fb.set_pixel(10, 20, 0x1234)
    assert_equal 0x1234, fb.pixel(10, 20)
  end

  def test_unwritten_pixel_reads_the_fill
    fb = advance_screen(fill: 0x7FFF)
    assert_equal 0x7FFF, fb.pixel(0, 0)
  end

  def test_out_of_bounds_write_is_clipped_not_an_error
    fb = advance_screen
    # Writing far off-screen must neither raise nor corrupt a real cell.
    fb.set_pixel(999, 999, 0x001F)
    fb.set_pixel(-5, -5, 0x001F)
    assert_equal 0, fb.pixel(0, 0)
  end

  def test_out_of_bounds_read_returns_nil
    fb = advance_screen
    assert_nil fb.pixel(240, 0)
    assert_nil fb.pixel(0, 160)
    assert_nil fb.pixel(-1, 0)
  end

  def test_fill_rect_fills_only_the_rectangle
    fb = advance_screen
    fb.fill_rect(2, 3, 4, 5, 0x00FF)
    assert_equal 0x00FF, fb.pixel(2, 3)
    assert_equal 0x00FF, fb.pixel(5, 7) # bottom-right corner (2+4-1, 3+5-1)
    assert_equal 0, fb.pixel(6, 3)      # just past the right edge
    assert_equal 0, fb.pixel(2, 8)      # just past the bottom edge
  end

  def test_fill_rect_clips_at_the_screen_edge
    fb = Framebuffer.new(width: 4, height: 4)
    fb.fill_rect(-1, -1, 10, 10, 0x0001) # overflows every edge
    # Every real cell got painted, and nothing raised.
    assert_equal [0x0001] * 16, fb.to_a
  end

  # fill_rect fills whole rows where it can, and #set_pixel a cell at a time is the plain way
  # it stands in for. Each of these paints the same rectangle both ways on screens set up
  # alike, and the pictures must match: held to an area, under a placed fade, with the scenery
  # kept apart, and see-through (which keeps to the cell-by-cell path).
  def test_fill_rect_matches_painting_cell_by_cell_inside_an_area
    assert_fill_rect_matches_cells { |fb| fb.draw_inside(3, 2, 6, 5) }
  end

  def test_fill_rect_matches_painting_cell_by_cell_under_a_placed_fade
    assert_fill_rect_matches_cells { |fb| fb.set_paint_fade(:black, 6) }
  end

  def test_fill_rect_matches_painting_cell_by_cell_with_the_scenery_kept
    assert_fill_rect_matches_cells(sprite_after: true, &:keep_scenery)
  end

  def test_fill_rect_matches_painting_cell_by_cell_see_through
    assert_fill_rect_matches_cells(tint_after: true) do |fb|
      fb.set_paint_see_through([8, 8])
    end
  end

  def test_fill_rect_of_no_width_or_height_paints_nothing
    fb = Framebuffer.new(width: 4, height: 4)
    fb.fill_rect(1, 1, 0, 3, 0x0001)
    fb.fill_rect(1, 1, 3, -2, 0x0001)
    assert_equal [0] * 16, fb.to_a
  end

  def test_clear_paints_every_pixel
    fb = Framebuffer.new(width: 3, height: 2)
    fb.clear(0x2222)
    assert_equal [0x2222] * 6, fb.to_a
  end

  # A console that keeps three bits of each colour channel (the Genesis) can only show the top
  # three bits of what a game painted, each widened back to five by repeating its top bits: a red of 5
  # keeps its top three bits (1) and is shown as 4, a green of 18 (4) as 18, a blue of 31 (7) as 31.
  def test_a_console_of_three_bit_colours_shows_the_top_three_bits_of_each_channel
    fb = Framebuffer.new(width: 2, height: 1, color_bits: 3)
    fb.set_pixel(0, 0, Color.rgb(5, 18, 31))

    assert_equal Color.rgb(4, 18, 31), fb.pixel(0, 0)
    assert_equal [Color.rgb(4, 18, 31), 0], fb.shown
  end

  def test_a_console_of_five_bit_colours_shows_every_bit
    fb = Framebuffer.new(width: 1, height: 1)
    fb.set_pixel(0, 0, Color.rgb(5, 18, 31))

    assert_equal Color.rgb(5, 18, 31), fb.pixel(0, 0)
  end

  # Two 12x10 screens with a pattern under the rectangle, set up by the block, then a rectangle
  # hanging off the left and top edges painted by fill_rect on one and by set_pixel on the
  # other. +sprite_after+ paints a see-through sprite over both afterwards, which is mixed with
  # the scenery kept apart; +tint_after+ tints both, which reads each mixed cell's two sides.
  private def assert_fill_rect_matches_cells(sprite_after: false, tint_after: false)
    rows = Array.new(2) do
      fb = Framebuffer.new(width: 12, height: 10)
      12.times { |x| 10.times { |y| fb.set_pixel(x, y, Color.rgb(x * 2, y * 3, 9)) } }
      yield fb
      fb
    end
    by_rows, by_cells = rows
    by_rows.fill_rect(-2, -1, 9, 7, Color.rgb(31, 4, 20))
    -1.upto(5) { |y| -2.upto(6) { |x| by_cells.set_pixel(x, y, Color.rgb(31, 4, 20)) } }
    [by_rows, by_cells].each do |fb|
      if sprite_after
        fb.set_paint_see_through([8, 8], sprite: true)
        fb.fill_rect(1, 1, 3, 3, Color.rgb(0, 31, 0))
      end
      fb.tint_to(Color.rgb(0, 0, 31), 50) if tint_after
    end

    assert_equal by_cells.to_a, by_rows.to_a
    assert_equal by_cells.shown, by_rows.shown
  end
end
