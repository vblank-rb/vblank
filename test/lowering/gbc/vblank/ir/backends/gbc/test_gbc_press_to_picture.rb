# frozen_string_literal: true

require "test_helper"

# A PRESS SHOWS ON THE FRAME AFTER IT, as the Color's own games show it. The console reads the
# buttons as a frame ends; the pass that runs next sees the press and moves a sprite, or scrolls a
# background; and the gap at the end of that pass sends the sprite table and the scroll to the
# display, so the frame after the press already shows the move. A Color cartridge sends them from a
# copy, so the pass places them in it before its wait (IR::Frames.loop_in_console_order); placed after,
# they would wait a pass in the copy and show a frame later.
class TestGBCPressToPicture < Minitest::Test
  PRESS = 40
  BAR_ROW = 140 # a row through the status bar of #bar_answering_a_press, on the Color's 144

  # A white square sprite, moved 16 pixels right on a press of Down; and a background of a white
  # column on black, scrolled 16 pixels left on the same press.
  private def moved_on_press
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:ball, "#" => :white) { "########\n" * 8 }
      image(:white_tile, "#" => :white) { "########\n" * 8 }
      image(:black_tile, "." => :black) { "........\n" * 8 }
      tiles :set, "w" => :white_tile, "." => :black_tile
      field = background :field, tiles: :set, map: Array.new(18) { ".....w" + ("." * 26) }
      ball = sprite :ball, at: [40, 100]
      across = 0
      game_loop do
        if pressed(:down)
          ball.x += 16
          across += 16
        end
        field.scroll_to across, 0
      end
    end
    b.finalize_program
    b.program
  end

  # A title menu's cursor: a sprite in a scene, moved on a press, in a game that does work of its
  # own every frame and keeps its sprites in order, which the builder puts in the gap after the
  # wait beside the sprites.
  private def cursor_in_a_scene
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:ball, "#" => :white) { "########\n" * 8 }
      image(:mark, "#" => :red) { "########\n" * 8 }
      ticks = 0
      once_a_frame { ticks += 1 }
      var :state, 0
      scene(:title) do
        cursor = sprite :ball, at: [40, 100]
        mark = sprite :mark, at: [100, 20]
        draw_in_order cursor, mark
        cursor.x += 16 if pressed(:down)
      end
      game_loop { case_var(:state) { when_val 0, :title } }
    end
    b.finalize_program
    b.program
  end

  # A red status bar along the bottom. On a press of Down one cell of it turns blue where the game
  # says now, and another as a change does, in the blank after the pass.
  private def bar_answering_a_press
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_tile, "#" => :red) { "########\n" * 8 }
      image(:blue_tile, "#" => :blue) { "########\n" * 8 }
      tiles :set, "r" => :red_tile, "b" => :blue_tile
      bar = status_bar :menu, tiles: :set, map: ["r" * 20], top: screen_height - 8
      game_loop do
        if pressed(:down)
          bar.set_tile 1, 0, "b", now: true
          bar.set_tile 5, 0, "b"
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The first frame, numbered from 1 at power-on, on which the block holds of the cartridge's picture.
  private def first_frame_where(program = moved_on_press)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "PRESS")
    down = VBlank::Console::Hardware::KEY_DOWN
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, keys: ->(played) { played + 1 == PRESS ? down : 0 })
    (1..(PRESS + 10)).find do |frame|
      v.step
      yield(v, frame)
    end
  end

  def test_a_sprite_moved_on_a_press_shows_on_the_frame_after_it
    white = 0x7FFF
    frame = first_frame_where { |v| v.pixel_gba(60, 104) == white && v.pixel_gba(44, 104) != white }

    assert_equal PRESS + 1, frame
  end

  def test_a_background_scrolled_on_a_press_shows_on_the_frame_after_it
    white = 0x7FFF
    # The column stands at 40 to 47 and scrolls to 24 to 31.
    frame = first_frame_where { |v| v.pixel_gba(28, 8) == white && v.pixel_gba(44, 8) != white }

    assert_equal PRESS + 1, frame
  end

  def test_a_cursor_in_a_scene_moved_on_a_press_shows_on_the_frame_after_it
    white = 0x7FFF
    frame = first_frame_where(cursor_in_a_scene) { |v| v.pixel_gba(60, 104) == white && v.pixel_gba(44, 104) != white }

    assert_equal PRESS + 1, frame
  end

  # A MENU IN THE BAR ANSWERS A PRESS ON THE FRAME THE PASS RUNS, since the screen has not reached the
  # bar's rows when the pass writes them; a cell left for the blank after the pass shows a frame on.
  def test_a_bar_cell_changed_now_shows_a_frame_before_one_left_for_the_blank
    blue = 0x7C00
    now = first_frame_where(bar_answering_a_press) { |v| v.pixel_gba(12, BAR_ROW) == blue }
    later = first_frame_where(bar_answering_a_press) { |v| v.pixel_gba(44, BAR_ROW) == blue }

    assert_equal later - 1, now
  end

  def test_a_bar_cell_changed_now_plays_as_the_interpreter_plays_it
    game_player.input_each_frame { |frame| frame == 5 ? [:down] : [] }.run(bar_answering_a_press, frames: 10)
  end

  # Left for the blank and then changed again now, the cell ends as the game last said, not as the
  # older change it left waiting.
  def test_a_cell_changed_for_the_blank_and_then_now_ends_as_the_last_change_said
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_tile, "#" => :red) { "########\n" * 8 }
      image(:blue_tile, "#" => :blue) { "########\n" * 8 }
      tiles :set, "r" => :red_tile, "b" => :blue_tile
      bar = status_bar :menu, tiles: :set, map: ["r" * 20], top: screen_height - 8
      game_loop do
        if pressed(:down)
          bar.set_tile 1, 0, "b"
          bar.set_tile 1, 0, "r", now: true
        end
      end
    end
    b.finalize_program
    red = 0x001F

    assert_nil first_frame_where(b.program) { |v, frame| frame > PRESS + 2 && v.pixel_gba(12, BAR_ROW) != red }
    game_player.input_each_frame { |frame| frame == 5 ? [:down] : [] }.run(b.program, frames: 10)
  end

  def test_a_game_that_changes_no_cell_now_keeps_no_room_for_it
    code = VBlank::IR::Backends::GBC.new.build(moved_on_press).built.code

    refute code.key?("rt_background_cell_shown"), "a game that does not ask pays nothing"
  end

  def test_a_cursor_in_a_scene_plays_as_the_interpreter_plays_it
    game_player.input_each_frame { |frame| frame == 5 ? [:down] : [] }.run(cursor_in_a_scene, frames: 10)
  end

  # What the pass placed before its wait is what the interpreter shows for that pass: the run
  # checks every pass's picture and numbers against it.
  def test_a_press_plays_as_the_interpreter_plays_it
    run = game_player.input_each_frame { |frame| frame == 5 ? [:down] : [] }.run(moved_on_press, frames: 10)

    assert_equal 16, run[:across]
  end
end
