# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE 320 x 240 SCREEN (`variants: { dos: :mode_x }`), in DOSBox, held to the interpreter pixel for pixel on
# every pass, and the card held to the game's picture (DOS::CheckedRun). Its picture is bigger than one
# segment of memory, so every drawing routine here reaches rows a plain screen does not have, and the card
# is sent the picture a plane at a time (DOS::Runtime::Rows, DOS::Runtime::ModeX).
class TestDOSModeX < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  BARS = %i[red red green green blue blue white white].freeze

  private def checked(frames: 2, &game)
    made = VBlank.game("DOSGAME", consoles: %i[dos], variants: { dos: :mode_x }, &game)
    DOS::CheckedRun.new.run(made.program(console: :dos), frames: frames)
  end

  private def colors(*names) = names.map { |name| VBlank::Graphics::Color.resolve(name) }

  def test_the_game_is_told_the_screen_is_240_rows
    run = checked do
      screen :bitmap
      rows = var :rows, 0
      rows = screen_height
      halt
    end

    assert_equal 240, run[:rows]
  end

  # The card itself, as a player's monitor is sent it: a picture of 240 rows, the picture the game drew in
  # its colours, and a pass for every one of its frames.
  def test_the_card_shows_240_rows_and_a_pass_a_frame
    game = VBlank.game("DOSGAME", consoles: %i[dos], variants: { dos: :mode_x }) do
      screen :bitmap
      passes = var :passes, 0
      clear_screen :blue
      fill_rect 317, 236, 3, 4, :white
      game_loop { passes += 1 }
    end
    exe = DOS.new.build(game.program(console: :dos))
    Dir.mktmpdir("dos-mode-x") do |dir|
      path = File.join(dir, "GAME.EXE")
      exe.write(path)
      probe = VBlank::Diagnostics::DOSProbe.new(path, hold: false)
      probe.step(10)
      started = probe.read32(exe.built.variables.fetch(:passes))
      probe.step(50)

      assert_equal 50, probe.read32(exe.built.variables.fetch(:passes)) - started
      assert_equal [320, 240], [probe.width, probe.height]
      shown = probe.frame_buffer.unpack("V*").map do |pixel|
        ((pixel & 0xFF) >> 3) | (((pixel >> 8) & 0xFF) >> 3 << 5) | (((pixel >> 16) & 0xFF) >> 3 << 10)
      end
      assert_equal colors(:blue, :white, :white, :blue), [[0, 0], [317, 236], [319, 239], [316, 239]].map { |x, y| shown[(y * 320) + x] }
    ensure
      probe&.close
    end
  end

  # A game that names the variant, built with the name that asks for none, is the plain 200-row program.
  def test_the_variant_named_none_builds_the_plain_screen
    game = VBlank.game("DOSGAME", consoles: %i[dos], variants: { dos: :mode_x }) do
      screen :bitmap
      rows = var :rows, 0
      rows = screen_height
      halt
    end
    run = DOS::CheckedRun.new.run(game.program(console: :dos, variant: :none), frames: 2)

    assert_equal 200, run[:rows]
  end

  # Row 204 is the first whose pixels are past 64K from the picture's start, and 239 the last there is.
  def test_every_kind_of_drawing_reaches_the_rows_past_the_first_segment
    run = checked do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      clear_screen :blue
      fill_rect 10, 190, 30, 50, :red
      fill_rect 300, 230, 40, 40, :green
      pixel 0, 204, :yellow
      pixel 319, 239, :yellow
      blit :bars, 100, 238
      blit :bars, 319, 210
      draw_text "ROWS", 150, 228, :white
      halt
    end

    assert_equal colors(:red, :red, :green, :yellow, :yellow, :blue),
                 [[10, 190], [39, 239], [310, 235], [0, 204], [319, 239], [5, 239]].map { |x, y| run.screen.pixel(x, y) }
  end

  # A pass that changes a few rows sends only those, and each plane's share of them lands in its own columns.
  def test_a_thing_moving_down_the_screen_is_shown_on_every_pass
    run = checked(frames: 40) do
      screen :bitmap
      y = var :y, 180
      clear_screen :black
      game_loop do
        draw_rect_at 157, y, 7, 3, :black
        y += 2
        draw_rect_at 157, y, 7, 3, :white
      end
    end

    assert_operator run[:y], :>, 240, "the thing went off the bottom of the screen"
  end

  # A sprite painted into the picture keeps the patch under it and puts it back as it moves.
  def test_a_painted_sprite_and_an_area_work_in_the_low_rows
    run = checked(frames: 8) do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      clear_screen :blue
      fill_rect 0, 220, 320, 20, :green
      inside(0, 200, 320, 36) { fill_rect 50, 190, 10, 60, :red }
      ship = sprite :bars, at: [20, 232]
      game_loop { ship.x += 3 }
    end

    assert_equal colors(:red, :blue, :green, :green), [[55, 235], [55, 199], [55, 236], [21, 233]].map { |x, y| run.screen.pixel(x, y) }
  end

  def test_sprites_stand_over_the_picture_in_the_low_rows
    checked(frames: 12) do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      clear_screen :blue
      fill_rect 0, 200, 320, 40, :green
      ship = sprite :bars, at: [30, 200], over_picture: true
      game_loop { ship.y += 4 }
    end
  end

  # The save memory comes after both pictures, which are bigger here, and its file is named as the program
  # starts, after the pictures are blanked.
  def test_a_game_that_saves_and_has_sprites_keeps_its_numbers
    run = checked(frames: 8) do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      best = save_var :best, 5
      clear_screen :blue
      ship = sprite :bars, at: [30, 230], over_picture: true
      game_loop do
        best += 2
        ship.x += 1
      end
    end

    assert_operator run[:best], :>, 5
  end

  def test_a_fade_moves_the_colours_of_the_whole_screen
    checked(frames: 20) do
      screen :bitmap
      clear_screen :white
      fill_rect 0, 210, 320, 30, :red
      passes = var :passes, 0
      game_loop do
        fade :black, passes * 10 if passes <= 10
        passes += 1
      end
    end
  end
end
