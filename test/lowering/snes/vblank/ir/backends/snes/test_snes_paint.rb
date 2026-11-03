# frozen_string_literal: true

require "test_helper"

# What a Super Nintendo cartridge paints on a painted (bitmap) screen is what the interpreter
# paints, pixel for pixel, after every pass (SNES::CheckedRun). Places and sizes are picked off the
# console's 8-pixel tile edges, and pictures are placed at every place across modulo eight, so a
# pixel shifted into the wrong tile, a mask a pixel short or a plane written to the wrong byte
# shows as a pixel in the wrong place.
class TestSNESPaint < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_rectangles_and_pixels_off_the_tile_edges
    run = checked(frames: 6) do
      screen :bitmap
      clear_screen :blue
      fill_rect 3, 5, 1, 9, :red        # one column inside a tile
      fill_rect 6, 2, 13, 4, :yellow    # across three tiles
      fill_rect 250, 218, 20, 20, :green # off the right and bottom edges
      fill_rect(-5, -3, 9, 6, :white)   # off the left and top
      x = 17
      game_loop do
        draw_rect_at x, 40, 1, 1, :magenta
        draw_rect_at x, 60, x / 4, 3, rgb(10, 20, 30)
        x += 5
      end
    end

    assert_equal Color.resolve(:red), run.screen.pixel(3, 5)
    assert_equal Color.resolve(:blue), run.screen.pixel(4, 5)
  end

  def test_clearing_inside_an_area_and_drawing_held_to_it
    run = checked(frames: 4) do
      screen :bitmap
      clear_screen :gray
      inside 13, 9, 30, 21 do
        clear_screen :blue
        fill_rect 0, 0, 100, 12, :orange
      end
      fill_rect 50, 50, 4, 4, :green # outside again: anywhere
      game_loop {}
    end

    assert_equal Color.resolve(:orange), run.screen.pixel(13, 9)
    assert_equal Color.resolve(:gray), run.screen.pixel(12, 9)
    assert_equal Color.resolve(:green), run.screen.pixel(51, 51)
  end

  def test_a_picture_at_every_place_across_and_off_every_edge
    run = checked(frames: 20) do
      screen :bitmap
      image :gem, "." => :transparent, "r" => :red, "g" => :green, "b" => :blue, "w" => :white do
        <<~ART
          ..rrrrgggg..
          .r........g.
          rr..wwww..gg
          b..........b
          .bbbbbbbbbb.
        ART
      end
      x = -6
      game_loop do
        clear_screen :black
        blit :gem, x, 7 + x
        blit :gem, 250 - x, 220 - x
        blit :gem, x * 3, -2
        x += 1
      end
    end

    assert_operator run[:x], :>, 10
  end

  def test_text_and_digits_in_a_picked_colour
    run = checked(frames: 12) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        draw_text "SCORE", 3, 4, :white
        draw_number n, 45, 4, :yellow, digits: 3
        draw_text "GO", 5, 30, %i[red green], showing: n % 2 == 1
        n += 7
      end
    end

    assert_equal 84, run[:n], "twelve passes"
  end

  def test_a_sprite_moving_over_a_painted_room_puts_back_what_it_covered
    run = checked(frames: 30) do
      screen :bitmap
      clear_screen :cyan
      fill_rect 40, 20, 30, 30, :orange
      image :ball, "." => :transparent, "o" => :white do
        ".oo.\noooo\noooo\n.oo.\n"
      end
      ball = sprite :ball, at: [30, 30]
      x = 30
      game_loop do
        x += 3
        ball.move_to x, 30 + (x / 8)
      end
    end

    assert_equal Color.resolve(:orange), run.screen.pixel(41, 21)
  end

  # A pass that clears the whole screen changes every one of its 896 tiles. Copied whole that is
  # 57344 bytes, fourteen blanks' worth. But a clear writes nothing: the tiles it covers show one
  # tile of the clear colour, so the pass sends that tile, the screen's map and the few tiles the
  # rectangle covers (30 pixels square at a place off the tile edges: five by five tiles, 1600 bytes),
  # all inside one blank. So each pass takes the one frame it takes on the interpreter, and none is
  # black. The checked run holds each pass's picture to the interpreter's; the frames between
  # passes are what only a player sees, read here one by one.
  def test_a_pass_that_clears_and_draws_a_little_takes_one_frame
    program = clear_and_draw_program
    SNES::CheckedRun.new.run(program, frames: 6) # raises if a pass's picture differs from the interpreter's
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 6)

    assert_empty run.black_frames
    assert_equal [1] * 5, (2..6).map { |pass| run.frames_took(pass) }
  end

  # The same on a cartridge with a Super FX, whose copy of the screen is the chip's RAM.
  def test_a_pass_that_clears_and_draws_a_little_takes_one_frame_on_the_super_fx
    program = clear_and_draw_program.tap { |game| game.variant = :superfx }
    SNES::CheckedRun.new.run(program, frames: 6)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 6)

    assert_empty run.black_frames
    assert_equal [1] * 5, (2..6).map { |pass| run.frames_took(pass) }
  end

  # Half the screen painted each pass, the left half and then the right, is 448 tiles (28672
  # bytes) for the blank: seven blanks' worth at least. While they arrive the screen must show the
  # last pass's whole picture, and then this pass's whole picture, never a mix: not half the new
  # tiles (a wipe down the screen), and not the old tiles in the new pass's faded colours.
  def test_a_big_change_and_its_colours_arrive_on_the_same_frame
    program = program_of do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        fade :black, (n % 4) * 20
        fill_rect 0, 0, 128, 224, :red if n % 2 == 0
        fill_rect 128, 0, 128, 224, :green if n % 2 == 1
        n += 1
      end
    end
    SNES::CheckedRun.new.run(program, frames: 5)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 5)

    assert_operator run.frames_took(3), :>, 1, "the half screen takes more than one blank"
    assert_empty run.black_frames
    assert_empty run.torn_frames
  end

  # A TILE ON THE SCREEN PAINTED AGAIN goes into the slot of video RAM its cell shows, so it is
  # seen the moment it arrives. In a big change those tiles go last, with the map, in one blank:
  # here a word at the top changes colour each pass while a band of the screen the last pass left
  # clear is filled — more than one blank's worth, of tiles not on the screen yet — and the word
  # must not change colour before the band arrives. Snake's title giving way to its board is this.
  def test_a_tile_painted_again_in_a_big_change_arrives_with_the_rest
    program = program_of do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        if n % 2 == 0
          draw_text "SNAKE", 8, 8, :green
          fill_rect 0, 112, 256, 56, :red
        end
        if n % 2 == 1
          draw_text "SNAKE", 8, 8, :white
          fill_rect 0, 168, 256, 56, :blue
        end
        n += 1
      end
    end
    SNES::CheckedRun.new.run(program, frames: 6)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 6)

    assert_operator run.frames_took(3), :>, 1, "the half screen takes more than one blank"
    assert_empty run.torn_frames
  end

  # ...and so when the generations come round, where every tile's generation is forgotten: a tile
  # on the screen then is still known to be, and still goes last.
  def test_a_tile_painted_again_as_the_generations_come_round_arrives_with_the_rest
    program = program_of do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        if n < 250
          n += 1
        else
          if n % 2 == 0
            draw_text "SNAKE", 8, 8, :green
            fill_rect 0, 112, 256, 56, :red
          end
          if n % 2 == 1
            draw_text "SNAKE", 8, 8, :white
            fill_rect 0, 168, 256, 56, :blue
          end
          n += 1
        end
      end
    end
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 262)

    assert_empty run.torn_frames
  end

  # A clear moves the screen on a generation, and a tile painted in an older one is the clear
  # colour. The count is a byte, so it comes round: the 257th clear has the number the first had.
  # The tile painted red after the first clear, and never since, must still be the clear colour then,
  # and the green square painted into it must show on the clear colour.
  def test_a_tile_painted_before_the_generations_come_round_is_cleared_after
    run = checked(frames: 257) do # the run ends on the pass n is 256 in
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :blue
        fill_rect 0, 0, 8, 8, :red if n == 0
        fill_rect 0, 0, 2, 2, :green if n == 256
        n += 1
      end
    end

    assert_equal Color.resolve(:green), run.screen.pixel(1, 1)
    assert_equal Color.resolve(:blue), run.screen.pixel(5, 5)
  end

  # THE CAMERA moves the view over the painted picture: screen (0, 0) shows what was painted at the
  # camera's place, and past the picture's edges the backdrop shows, black, faded with the rest. The
  # picture has a different colour along each edge, so a view that wraps round shows one edge's
  # colour where the backdrop should be. The view goes past every edge, and past the picture
  # altogether, from -330 to 326 across (in a shuffled order, so a view far up or down is not
  # always far across too) and -330 to 310 down, and once to 65546 across: far enough that a view
  # not held to the picture's size would come round onto it.
  def test_the_camera_shows_the_backdrop_past_every_edge_of_the_picture
    run = checked(frames: 17) do
      screen :bitmap
      clear_screen :gray
      fill_rect 0, 0, 256, 8, :red        # the top edge
      fill_rect 0, 216, 256, 8, :green    # the bottom edge
      fill_rect 0, 0, 8, 224, :blue       # the left edge
      fill_rect 248, 0, 8, 224, :yellow   # the right edge
      t = 0
      game_loop do
        camera (((t * 7) % 17) * 41) - 330, (t * 40) - 330
        camera 65_546, 3 if t == 16
        fade :white, (t % 3) * 25
        t += 1
      end
    end

    assert_equal 17, run[:t]
  end

  # Breakout's shake: the camera jolted a few pixels and put back.
  def test_a_shaken_screen_shows_what_the_interpreter_shows
    run = checked(frames: 12) do
      screen :bitmap
      clear_screen :gray
      fill_rect 100, 100, 20, 20, :red
      n = 0
      game_loop do
        shake_screen intensity: 3, frames: 6 if n == 2
        n += 1
      end
    end

    assert_equal 12, run[:n]
  end

  # A tiled screen's view moves with `scroll_to`; the camera there is refused in plain words, as
  # it is on the Advance.
  def test_the_camera_on_a_tiled_screen_is_refused_in_plain_words
    error = assert_raises(SNES::LoweringError) do
      SNES.new.build(program_of do
        screen :tiled
        game_loop { camera 3, 3 }
      end)
    end

    assert_match(/scroll_to/, error.message)
  end

  # A PAINTED SPRITE moving every pass costs the patch under it put back, the patch at its new place
  # kept, and its picture painted there: a 16×16 picture at a place off the tile edges touches nine
  # tiles. That all fits one frame, as on the interpreter.
  def test_a_painted_sprite_moving_every_pass_keeps_up_with_the_screen
    program = program_of do
      screen :bitmap
      clear_screen rgb(0, 0, 8)
      2.times do |k|
        image(:"coin#{k}", "." => :transparent, "Y" => :yellow, "o" => :orange) do
          Array.new(16) { |row| Array.new(16) { |col| (row + col + k).even? ? "Y" : (col > 2 && col < 13 ? "o" : ".") }.join }.join("\n")
        end
      end
      coin = sprite :coin, at: [37, 41], frames: %i[coin0 coin1], rate: 2
      game_loop { coin.move :right, by: 3 }
    end
    SNES::CheckedRun.new.run(program, frames: 10)
    run = SNES::HeadlessRun.new.run(program, frames: 10)

    assert_equal [1] * 9, (2..10).map { |pass| run.frames_took(pass) }
  end

  # Which pixels of each tile column a painting may touch is worked out once a picture or a patch,
  # and a picture painted inside a narrow area holds its columns to that area. The sprite's patch put
  # back after it, in the same columns, is held to the whole screen again: every pixel it covered.
  def test_a_patch_put_back_after_a_picture_held_to_an_area_puts_back_every_pixel
    run = checked(frames: 12) do
      screen :bitmap
      clear_screen :cyan
      image(:dot, "o" => :red) { "oooooooooooooooo\n" * 4 }
      image(:ball, "." => :transparent, "o" => :white) { "oooooooooooo\n" * 6 }
      ball = sprite :ball, at: [0, 2]
      x = 0
      game_loop do
        inside(0, 0, 12, 12) { blit :dot, 0, 0 }
        x += 2
        ball.move_to x, 2
      end
    end

    assert_equal Color.resolve(:cyan), run.screen.pixel(1, 7)
  end

  # A PASS THAT PAINTS WHAT THE LAST ONE DID costs almost nothing: a clear and the same paintings
  # at the same places leave every tile as it was, so none is painted again or sent. The menu
  # tests' game clears and draws four rows and a cursor every pass, and a tap moves the cursor,
  # which paints two rows and the cursor again: each pass takes one frame, the first included,
  # as on the interpreter.
  def test_the_menu_tests_game_takes_one_frame_a_pass
    program = program_of do
      screen :bitmap
      chose = var :chose, 0
      game_loop do
        clear_screen :black
        menu(:main, at: [60, 40], spacing: 20, color: :gray, picked: :white, disabled: :red, press: :a) do |rows|
          %w[ONE TWO THREE FOUR].each_with_index { |label, i| rows.item(label, enabled: i != 1) { chose = i + 1 } }
        end
      end
    end
    taps = ->(frame) { frame % 3 == 1 ? [:down] : [] }
    SNES::CheckedRun.new.input_each_frame(&taps).run(program, frames: 12)
    run = SNES::HeadlessRun.new.input_each_frame(&taps).run(program, frames: 12)

    assert_equal [1] * 11, (2..12).map { |pass| run.frames_took(pass) }
  end

  # Four rows of 21 letters, cleared and written again every pass, the same each time: once the
  # first pass has painted them, each pass takes one frame. Painting them every pass took six.
  def test_four_rows_of_unchanged_text_take_one_frame_a_pass
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        4.times { |row| draw_text "ABCDEFGHIJKLMNOPQRSTU", 8, 40 + (row * 20), :white }
      end
    end
    SNES::CheckedRun.new.run(program, frames: 8)
    run = SNES::HeadlessRun.new.run(program, frames: 8)

    assert_equal [1] * 5, (4..8).map { |pass| run.frames_took(pass) }
  end

  # Text that changes every pass beside text that does not: the changed tiles are painted again
  # and sent, and the rest are left alone, which the interpreter's picture checks pass by pass.
  def test_text_that_changes_every_pass_beside_text_that_does_not
    run = checked(frames: 12) do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :blue
        draw_text "SCORE", 8, 8, :white
        draw_number n, 60, 8, :yellow, digits: 3
        draw_text "LEFT", 9, 30, %i[red green], showing: n % 2 == 1
        draw_number n / 3, 41, 31, :white, digits: 2
        n += 1
      end
    end

    assert_equal 12, run[:n]
  end

  # TWO PAINTINGS THAT SHARE A TILE, one changing and one not: the tile is painted again with
  # both, in the order the game painted them. A bar under a picture whose colour changes, a
  # picture over a bar that moves a pixel at a time, and a rectangle over both, each across tile
  # edges, so a tile painted with only the paintings that changed, or in the wrong order, shows.
  def test_paintings_that_share_a_tile_come_out_in_order
    run = checked(frames: 14) do
      screen :bitmap
      image :gem, "." => :transparent, "r" => :red, "w" => :white do
        ".rrrr.\nrwwwwr\n.rrrr.\n"
      end
      n = 0
      game_loop do
        clear_screen :black
        fill_rect 3, 3, 20, 6, :green
        blit :gem, 6, 4 if n % 2 == 0
        draw_text "A", 13, 2, %i[yellow cyan], showing: n % 4 < 2
        draw_rect_at 30 + (n % 5), 12, 9, 5, :orange
        blit :gem, 33, 11
        fill_rect 10, 6, 3, 3, :magenta
        n += 1
      end
    end

    assert_equal Color.resolve(:magenta), run.screen.pixel(10, 6), "the last painting is on top"
  end

  # A bar across two tiles, a square over it in the first, and a dot that moves in the second:
  # the bar is painted again for the second tile, and so the first is painted again too, square
  # and all. Later passes paint a dot into the first tile without clearing, on what is there,
  # so a first tile left with the bar over its square would show.
  def test_a_painting_done_again_takes_every_painting_of_its_tiles_with_it
    run = checked(frames: 10) do
      screen :bitmap
      n = 0
      game_loop do
        if n < 6
          clear_screen :black
          fill_rect 0, 40, 16, 8, :green
          fill_rect 2, 42, 3, 3, :white
          draw_rect_at 10 + (n % 3), 42, 2, 2, :red
        end
        fill_rect 6, 46, 1, 1, :yellow if n >= 6
        n += 1
      end
    end

    assert_equal Color.resolve(:white), run.screen.pixel(3, 43), "the square stays over the bar"
  end

  # Painted again every pass, a painting under a clear made at once in an earlier pass, and a
  # sprite's patch kept and put back over a screen that was cleared: what a pass paints at once
  # and what it writes down meet in the same tiles.
  def test_a_sprite_over_a_screen_cleared_every_other_pass
    run = checked(frames: 16) do
      screen :bitmap
      image :ball, "." => :transparent, "o" => :white do
        ".oo.\noooo\noooo\n.oo.\n"
      end
      ball = sprite :ball, at: [10, 10]
      n = 0
      game_loop do
        clear_screen :blue if n % 2 == 0
        fill_rect 8, 8, 12, 12, :red
        draw_rect_at 4 + n, 9, 5, 3, :yellow
        ball.move_to 6 + (n * 2), 10
        n += 1
      end
    end

    assert_equal 16, run[:n]
  end

  private def clear_and_draw_program
    program_of do
      screen :bitmap
      x = 3
      game_loop do
        clear_screen :blue
        draw_rect_at x, 21, 30, 30, :yellow
        x += 7
      end
    end
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames:, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
