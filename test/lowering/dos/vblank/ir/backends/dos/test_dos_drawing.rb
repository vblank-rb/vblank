# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# DRAWING ON THE VGA CARD, in DOSBox, held to the interpreter pixel for pixel on every pass (DOS::CheckedRun):
# what the first games of test_dos_checked_run.rb do not reach. A checked run that ends is a picture that
# agreed everywhere, so most of these assert only a pixel or two that show the test drew what it meant to.
class TestDOSDrawing < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  BARS = %i[red red green green blue blue white white].freeze

  private def checked(frames: 2, &game)
    DOS::CheckedRun.new.run(VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos), frames: frames)
  end

  # Every kind of drawing, each partly inside the area and partly outside it, on every side.
  def test_every_drawing_is_held_to_an_area
    run = checked do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      clear_screen :blue
      inside 40, 20, 120, 80 do
        clear_screen :black
        fill_rect 30, 10, 20, 20, :red
        fill_rect 150, 90, 40, 40, :green
        draw_rect_at 100, 0, 8, 200, :white
        pixel 39, 50, :yellow
        pixel 40, 50, :yellow
        pixel 159, 99, :yellow
        pixel 160, 100, :yellow
        blit :bars, 39, 19
        blit :bars, 159, 97
        draw_text "EDGE", 30, 60, :white
        draw_text "EDGE", 140, 95, :white
      end
      halt
    end

    assert_equal [VBlank::Graphics::Color.resolve(:blue), VBlank::Graphics::Color.resolve(:yellow)],
                 [run.screen.pixel(39, 50), run.screen.pixel(40, 50)]
  end

  # One area is in force at a time: the second is its own, and when each block ends drawing is held to
  # nothing but the screen again.
  def test_an_area_ends_with_its_block
    run = checked do
      screen :bitmap
      clear_screen :blue
      inside(100, 100, 20, 20) { fill_rect 0, 0, 320, 200, :red }
      inside(10, 10, 50, 50) { fill_rect 0, 0, 320, 200, :green }
      pixel 300, 190, :white
      halt
    end

    assert_equal %i[red green white blue].map { |color| VBlank::Graphics::Color.resolve(color) },
                 [run.screen.pixel(110, 110), run.screen.pixel(30, 30), run.screen.pixel(300, 190), run.screen.pixel(80, 80)]
  end

  # An area off the screen, or of no size, is one nothing is drawn in.
  def test_an_area_off_the_screen_or_of_no_size_takes_no_drawing
    run = checked do
      screen :bitmap
      clear_screen :blue
      inside(-50, -50, 40, 40) { fill_rect(-60, -60, 400, 300, :red) }
      inside(300, 180, 100, 100) { fill_rect 0, 0, 320, 200, :green }
      inside(50, 50, 0, 10) { fill_rect 0, 0, 320, 200, :white }
      halt
    end

    assert_equal [VBlank::Graphics::Color.resolve(:blue), VBlank::Graphics::Color.resolve(:green)],
                 [run.screen.pixel(60, 55), run.screen.pixel(310, 190)]
  end

  # A game whose frames end while an area is open goes on drawing inside it on every pass.
  def test_an_area_stays_open_across_frames
    checked(frames: 5) do
      screen :bitmap
      clear_screen :blue
      x = var :x, 0
      inside 40, 20, 120, 80 do
        game_loop do
          draw_rect_at x, 30, 30, 30, :red
          x += 37
        end
      end
    end
  end

  # One of several pictures, picked by a number the game works out: each in turn, and none for a number
  # that is not one of them.
  def test_one_of_several_pictures_is_drawn_by_its_number
    run = checked(frames: 6) do
      screen :bitmap
      image :red_square, width: 2, height: 2, data: %i[red red red red]
      image :green_square, width: 2, height: 2, data: %i[green green green green]
      image :white_square, width: 2, height: 2, data: %i[white white white white]
      which = var :which, -1
      game_loop do
        clear_screen :black
        blit %i[red_square green_square white_square], 318 + which, 100 + (which * 20), showing: which
        which += 1
      end
    end

    assert_equal 5, run[:which]
  end

  # A FADE AND A TINT MOVE THE CARD'S PALETTE, not the picture: every colour the game shows, a sprite's over
  # the picture among them, toward black, then white, then a colour, each a little further every pass and
  # then lifted, with the interpreter's own rounding on every pass.
  def test_fades_and_a_tint_walk_every_colour_and_lift_again
    run = checked(frames: 40) do
      screen :bitmap
      image :block, width: 6, height: 6, data: [:white] * 36
      clear_screen :blue
      fill_rect 10, 10, 60, 60, :red
      fill_rect 80, 10, 60, 60, :green
      fill_rect 150, 10, 60, 60, :yellow
      sprite :block, at: [30, 30], over_picture: true
      passes = var :passes, 0
      game_loop do
        fade :black, passes * 10 if passes < 10
        fade :white, (passes - 10) * 10 if passes >= 10 && passes < 20
        tint :orange, (passes - 20) * 10 if passes >= 20 && passes < 30
        tint :orange, 0 if passes >= 30
        passes += 1
      end
    end

    assert_equal %i[red green yellow white].map { |color| VBlank::Graphics::Color.resolve(color) },
                 [run.screen.pixel(12, 12), run.screen.pixel(82, 12), run.screen.pixel(152, 12), run.screen.pixel(32, 32)],
                 "every colour as it was drawn, once the tint is lifted"
  end

  # A fade still on when the game stops is on the picture the game stops with.
  def test_a_fade_in_force_when_the_game_halts_is_shown
    run = checked do
      screen :bitmap
      clear_screen :white
      fade :black, 100
      halt
    end

    assert_equal 0, run.screen.pixel(10, 10)
  end

  # Part way to black every colour is darker than it was drawn and not yet black.
  def test_a_fade_part_way_darkens_and_does_not_blacken
    run = checked(frames: 3) do
      screen :bitmap
      clear_screen :white
      game_loop { fade :black, 50 }
    end
    shown = run.screen.pixel(10, 10)

    assert_operator shown, :<, VBlank::Graphics::Color.resolve(:white)
    assert_operator shown, :>, 0
  end

  def test_a_fade_of_part_of_the_screen_is_refused_by_name
    error = assert_raises(DOS::Lowering::NotMadeYet) do
      checked do
        screen :bitmap
        clear_screen :white
        game_loop { fade :black, 50, inside: [0, 0, 40, 40] }
      end
    end

    assert_match(/fades part of the screen/, error.message)
  end

  # THE CARD SHOWS WHAT THE GAME DREW. The game draws in a picture of its own, and the card is sent the rows
  # that changed as each retrace begins: a square that moves leaves nothing behind it on the card, and the
  # whole of what was drawn before the loop is there, though no pass after the first drew it again.
  def test_the_card_shows_the_picture_the_game_drew
    game = VBlank.game("DOSGAME", consoles: %i[dos]) do
      screen :bitmap
      clear_screen :blue
      fill_rect 300, 190, 20, 10, :green
      x = var :x, 0
      game_loop do
        draw_rect_at x, 50, 10, 10, :blue
        x += 3
        draw_rect_at x, 50, 10, 10, :white
      end
    end
    exe = DOS.new.build(game.program(console: :dos))
    Dir.mktmpdir("dos-drawing") do |dir|
      path = File.join(dir, "GAME.EXE")
      exe.write(path)
      probe = VBlank::Diagnostics::DOSProbe.new(path)
      probe.step(20)
      x = probe.read32(exe.built.variables.fetch(:x))
      shown = probe.frame_buffer.unpack("V*")
      colors = shown.each_slice(320).to_a[55]
      white = colors.each_index.select { |column| colors[column] == 0xFFFFFF }

      assert_equal 10, white.size, "one square, with no trail"
      assert_includes [x, x - 3], white.first, "where the last pass shown put it"
      assert_equal [0x00FF00], shown.each_slice(320).to_a[195][300, 20].uniq
    ensure
      probe&.close
    end
  end

  # A TEAR-FREE SCREEN IS THE PAINTED SCREEN AS IT ALWAYS IS ON A PC: one picture in memory, sent to the card
  # in the retrace. So what a game paints once is there on every pass after, where a console that shows
  # two pictures in turn shows it on every other one, and the program is the one `screen :bitmap` builds.
  def test_a_tear_free_screen_keeps_what_was_painted_once_on_every_pass
    game = lambda do |tear_free|
      VBlank.game("DOSGAME", consoles: %i[dos]) do
        screen :bitmap, tear_free: tear_free
        clear_screen :blue
        fill_rect 10, 10, 30, 30, :red
        passes = var :passes, 0
        game_loop { passes += 1 }
      end.program(console: :dos)
    end
    seen = [3, 4].map { |frames| DOS::CheckedRun.new.run(game.call(true), frames: frames).screen.pixel(20, 20) }

    assert_equal [VBlank::Graphics::Color.resolve(:red)] * 2, seen
    assert_equal DOS.new.build(game.call(false)).bytes, DOS.new.build(game.call(true)).bytes
  end
end
