# frozen_string_literal: true

require "test_helper"

# What only the PlayStation's own program can show about a painted screen: where the picture is in
# its video RAM, read straight from the emulator (PS1::HeadlessRun), and that the checked run reads
# every pixel of it. What the verbs draw is in test/all, where this run plays them against the
# interpreter pixel for pixel.
class TestPS1PaintedScreen < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  RED = VBlank::Graphics::Color.resolve(:red)

  # The checked run compares the whole picture: the screen the interpreter plays is the PlayStation's,
  # its bottom right corner included. (The builder checks a written number against the Advance's
  # screen, so the corner is a number the game works out.)
  def test_the_checked_run_reads_the_whole_picture
    run = PS1::CheckedRun.new.run(program_of do
      right = 319
      bottom = 239
      game_loop do
        clear_screen :blue
        draw_rect_at right, bottom, 1, 1, :red
      end
    end, frames: 3)

    assert_equal [320, 240], [run.screen.width, run.screen.height]
    assert_equal 320 * 240, run.screen.shown.size
    assert_equal RED, run.screen.pixel(319, 239)
    assert_equal BLUE, run.screen.pixel(318, 239)
  end

  # A tear-free screen draws each pass into the page not shown, and the pages trade places at the frame
  # boundary: the console shows each pass's picture, which the check reads from the page the chip
  # displays (PS1::HeadlessRun#picture_of_pass), so pages that did not trade places are a difference.
  def test_a_tear_free_screen_shows_each_passes_picture
    run = PS1::CheckedRun.new.run(program_of do
      screen :bitmap, tear_free: true
      n = 0
      game_loop do
        n += 1
        clear_screen :blue
        draw_rect_at 0, 0, n, 4, :red
      end
    end, frames: 7)

    assert_equal RED, run.screen.pixel(6, 0)
    assert_equal BLUE, run.screen.pixel(7, 0)
  end

  # A black pixel of a picture is 0000h, the one texel the graphics chip leaves undrawn, so the picture
  # keeps it with its top bit set (PaintedArt, TEXEL_DRAWN): drawn black, not see-through.
  def test_a_black_pixel_of_a_picture_is_drawn_black
    run = PS1::CheckedRun.new.run(program_of do
      image :eye, "K" => :black, "W" => :white, "." => :transparent do
        "WK."
      end
      game_loop do
        clear_screen :red
        blit :eye, 10, 10
      end
    end, frames: 3)

    assert_equal [VBlank::Graphics::Color.resolve(:white), 0, RED], [10, 11, 12].map { |x| run.screen.pixel(x, 10) }
  end

  # A picture wider than one piece the graphics chip reads (PaintedArt::PIECE_WIDTH) is drawn as several,
  # each in its place, and cut at both edges of the screen as the interpreter cuts it.
  def test_a_picture_cut_into_pieces_lands_whole_and_clipped
    run = PS1::CheckedRun.new.run(program_of do
      image :band, data: Array.new(300 * 4) { |i| ((i * 37) & 0x7FFF) | 1 }, width: 300, height: 4
      x = var :x, -40
      game_loop do
        clear_screen :black
        blit :band, x, 10
        blit :band, 100, 237
        x += 7
      end
    end, frames: 12)

    assert_equal 1, run.screen.pixel(100, 237), "the band's first pixel, at the bottom edge"
  end

  # The pictures go beside the screen's pages in video RAM, and a game whose pictures do not fit there
  # is refused in plain words.
  def test_pictures_too_big_for_video_ram_are_refused
    error = assert_raises(PS1::PaintedArt::Full) do
      PS1.new.build(program_of do
        8.times do |n|
          image :"big#{n}", data: Array.new(192 * 256) { |i| (i + n) | 1 }, width: 192, height: 256
        end
        game_loop { 8.times { |n| blit :"big#{n}", 0, 0 } }
      end)
    end

    assert_match(/video memory/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end
end
