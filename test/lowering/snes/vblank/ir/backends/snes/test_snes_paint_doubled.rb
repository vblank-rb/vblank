# frozen_string_literal: true

require "test_helper"

# A PAINTED SCREEN OF BIG PIXELS ON THE SUPER NINTENDO'S CARTRIDGE (`screen :bitmap, pixel_size: 2`,
# Runtime::PaintDoubled): Mode 7's layer shows each of the game's pixels as a square of four, and a
# pass's change is copied a byte a pixel. What a game sees of it, held to the interpreter, is
# test/console/snes/vblank/builder/test_screen_pixel_size_on_the_super_nintendo.rb.
#
# What is measured is the copy: a game repaints its whole small picture in another colour every
# pass, and video memory read after every frame says how many of the picture's bytes arrived in
# that frame, and the game's count of its passes how many it showed a second.
# VBLANK_DOUBLED_BYTES=1 prints both.
class TestSNESPaintDoubled < Minitest::Test
  # The picture's bytes: 128×112, one a pixel, in the high bytes of video memory's first words.
  PICTURE_BYTES = 128 * 112
  # The console's four pixels that show one of the game's, from its top left.
  SQUARE = [[0, 0], [1, 0], [0, 1], [1, 1]].freeze

  private def repainting_game(rows: nil)
    VBlank.game("REPAINT", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2, shown_rows: rows
      step = var :step, 0
      game_loop do
        step += 1
        if step % 2 == 1
          fill_rect 0, 0, 128, 112, :red
        else
          fill_rect 0, 0, 128, 112, :blue
        end
      end
    end
  end

  # The high byte of each of the picture's words of video memory: its tiles' pixels.
  private def picture_bytes(reader)
    words = reader.video_ram.byteslice(0, PICTURE_BYTES * 2)
    (0...PICTURE_BYTES).map { |at| words.getbyte((at * 2) + 1) }
  end

  # The most of the picture's bytes that arrived in one frame, and the passes shown a second.
  private def copy_measured(rows)
    reader = VBlank::Diagnostics::Verifier.new(repainting_game(rows: rows).build_rom(console: :snes), frames: 30)
    before = picture_bytes(reader)
    first_step = reader.var(:step)
    most = 0
    frames = 120
    frames.times do
      reader.step
      now = picture_bytes(reader)
      most = [most, now.each_index.count { |at| now[at] != before[at] }].max
      before = now
    end
    [most, (reader.var(:step) - first_step) * 60.0 / frames]
  end

  def test_each_pixel_of_the_game_fills_a_square_of_four
    game = VBlank.game("SQUARES", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      game_loop do
        clear_screen :blue
        fill_rect 3, 5, 7, 9, :red
        pixel 127, 111, :white
        pixel 0, 0, :green
      end
    end
    reader = VBlank::Diagnostics::Verifier.new(game.build_rom(console: :snes), frames: 20)
    picture = reader.frame_gba

    odd = (0...112).flat_map do |y|
      (0...128).reject do |x|
        square = SQUARE.map { |dx, dy| picture[(((y * 2) + dy) * 256) + (x * 2) + dx] }
        square.uniq.one?
      end
    end
    assert_empty odd, "every square is one colour"
    assert_equal VBlank::Graphics::Color.resolve(:white), picture[(223 * 256) + 255]
    assert_equal VBlank::Graphics::Color.resolve(:red), picture[(10 * 256) + 6]
  end

  def test_a_whole_repaint_copies_in_fewer_frames_with_rows_given_up
    whole, whole_rate = copy_measured(nil)
    shortened, shortened_rate = copy_measured(16...96)
    if ENV["VBLANK_DOUBLED_BYTES"]
      warn "whole screen: #{whole} bytes a frame, #{whole_rate} passes a second; " \
           "rows 16 to 95 shown: #{shortened} bytes a frame, #{shortened_rate} passes a second"
    end

    assert_operator whole, :<=, 6_144, "a blank alone holds what Runtime::Blank counts"
    assert_operator whole_rate, :>=, 15, "the whole small picture goes in three blanks or four"
    assert_operator shortened, :>, 6_144, "the lines kept off hold more than a blank"
    assert_operator shortened_rate, :>=, 59, "with 64 of the console's lines kept off, a 128x80 picture goes every frame"
  end

  # What the screen of big pixels does not paint yet is refused by name as the build begins.
  def test_a_column_drawn_stretched_is_refused_with_big_pixels
    game = VBlank.game("COLUMNS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      image(:bars, "#" => :red) { "##\n##" }
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 20, height: 40 }
    end
    error = assert_raises(VBlank::IR::Backends::SNES::Lowering::NotMadeYet) do
      game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new)
    end

    assert_match(/draw_column_at/, error.message)
  end
end
