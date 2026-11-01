# frozen_string_literal: true

require "test_helper"

# A PRESS SHOWS ON THE FRAME AFTER IT, as the console's own games show it. An emulated frame starts
# with the blank, whose interrupt reads the buttons; the pass that runs in that frame sees the press
# and moves a sprite, or scrolls a background; and the next blank sends the sprite table and the
# scroll, so the next frame shows the move. This cartridge sends them from a copy, as the Color's
# does, so a pass places them in it before its wait (IR::Frames.loop_in_console_order); placed
# after, they wait a pass in the copy and show a frame later.
class TestSNESPressToPicture < Minitest::Test
  PRESS = 40

  # A white square sprite, moved 16 pixels right on a press of Down; and a background of a white
  # column on black, scrolled 16 pixels left on the same press.
  private def moved_on_press
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:ball, "#" => :white) { "########\n" * 8 }
      image(:white_tile, "#" => :white) { "########\n" * 8 }
      image(:black_tile, "." => :black) { "........\n" * 8 }
      tiles :set, "w" => :white_tile, "." => :black_tile
      field = background :field, tiles: :set, map: Array.new(32) { ".....w#{'.' * 26}" }
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
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
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

  # The first frame, numbered from 1 at power-on, on which the block holds of the cartridge's
  # picture, handed a way to read a pixel.
  private def first_frame_where(program = moved_on_press)
    rom = VBlank::Console.for(:snes).builder.cartridge_for(program, title: "PRESS")
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.sfc") do |core|
      (1..(PRESS + 10)).find do |frame|
        core.set_buttons(frame == PRESS ? [:down] : [])
        core.run_frame
        colors = core.colors
        yield(->(x, y) { colors[(y * core.width) + x] })
      end
    end
  end

  WHITE = 0x7FFF

  def test_a_sprite_moved_on_a_press_shows_on_the_frame_after_it
    frame = first_frame_where { |pixel| pixel.call(60, 104) == WHITE && pixel.call(44, 104) != WHITE }

    assert_equal PRESS + 1, frame
  end

  def test_a_background_scrolled_on_a_press_shows_when_the_sprite_does
    # The column stands at 40 to 47 and scrolls to 24 to 31.
    frame = first_frame_where { |pixel| pixel.call(28, 8) == WHITE && pixel.call(44, 8) != WHITE }

    assert_equal PRESS + 1, frame
  end

  def test_a_cursor_in_a_scene_moved_on_a_press_shows_on_the_frame_after_it
    frame = first_frame_where(cursor_in_a_scene) { |pixel| pixel.call(60, 104) == WHITE && pixel.call(44, 104) != WHITE }

    assert_equal PRESS + 1, frame
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
