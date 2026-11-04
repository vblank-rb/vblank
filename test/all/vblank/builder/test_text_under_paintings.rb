# frozen_string_literal: true

require "test_helper"

# Text on a painted screen with paintings over it, under it and beside it. A console may show text
# at a place known when the game is built on a layer of its own, in front of the picture (the
# Super Nintendo does), so whatever is painted over text later must still cover it, in the order
# the game drew them. Every run checks its picture against the interpreter's on every pass; the
# pixels asserted here say what that picture is.
class TestTextUnderPaintings < Minitest::Test
  WHITE = VBlank::Graphics::Color.resolve(:white)
  RED = VBlank::Graphics::Color.resolve(:red)
  YELLOW = VBlank::Graphics::Color.resolve(:yellow)
  BLACK = VBlank::Graphics::Color.resolve(:black)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def screen_after(frames, &game) = game_player.run(program(&game), frames: frames).screen

  # Whether any pixel of the rectangle is +color+.
  private def any_in?(shown, color, x, y, w, h)
    (x...(x + w)).any? { |px| (y...(y + h)).any? { |py| shown.pixel(px, py) == color } }
  end

  def test_a_rectangle_painted_over_text_in_the_same_pass_covers_it
    shown = screen_after(3) do
      screen :bitmap
      game_loop do
        clear_screen :black
        draw_text "HELLO", 16, 16, :white
        fill_rect 16, 16, 10, 7, :red
      end
    end

    assert_equal RED, shown.pixel(16, 16)
    refute any_in?(shown, WHITE, 16, 16, 10, 7), "no letter shows through the rectangle"
    assert any_in?(shown, WHITE, 28, 16, 20, 7), "the letters past it show"
  end

  def test_text_under_paintings_on_passes_that_do_not_clear
    shown = screen_after(6) do
      screen :bitmap
      n = 0
      game_loop do
        if n == 0
          clear_screen :black
          draw_text "HELLO", 16, 16, :white
        else
          draw_rect_at 14 + (n * 2), 16, 2, 7, :red
        end
        n += 1
      end
    end

    refute any_in?(shown, WHITE, 16, 16, 10, 7), "the rectangles cover the first letters"
    assert any_in?(shown, WHITE, 28, 16, 20, 7), "the letters past them show"
  end

  def test_text_written_over_text_shows_on_top
    shown = screen_after(3) do
      screen :bitmap
      game_loop do
        clear_screen :black
        draw_text "AAAA", 16, 16, :white
        draw_text "BBBB", 18, 16, :yellow
      end
    end

    assert_equal YELLOW, shown.pixel(18, 16)
  end

  # Passes that draw what the last one drew, and then one more painting every other pass: the
  # passes in between show the text whole again.
  def test_a_rectangle_over_text_every_other_pass
    pictures = [6, 7].map do |frames|
      screen_after(frames) do
        screen :bitmap
        n = 0
        game_loop do
          clear_screen :black
          draw_text "HELLO", 16, 16, :white
          fill_rect 16, 16, 10, 7, :red if n % 2 == 1
          n += 1
        end
      end
    end

    assert_equal 1, pictures.count { |shown| shown.pixel(16, 16) == RED }, "the rectangle shows on one of two passes"
    assert(pictures.any? { |shown| any_in?(shown, WHITE, 16, 16, 10, 7) }, "the words show whole on the other")
  end

  def test_text_inside_an_area_is_held_to_it
    shown = screen_after(3) do
      screen :bitmap
      game_loop do
        clear_screen :black
        inside(0, 0, 22, 100) { draw_text "HELLO", 16, 16, :white }
      end
    end

    assert any_in?(shown, WHITE, 16, 16, 6, 7)
    refute any_in?(shown, WHITE, 22, 16, 30, 7), "nothing past the area's edge"
  end

  # The same text on every pass, held to a narrower area after the first: a console that passes
  # over a text the last pass drew too must see that its area changed.
  def test_text_in_an_area_that_narrows_is_held_to_it
    shown = screen_after(4) do
      screen :bitmap
      func(:words) { draw_text "PRESS START", 16, 100, :white }
      n = 0
      game_loop do
        clear_screen :black
        if n == 0
          call :words
        else
          inside(0, 0, 40, screen_height) { call :words }
        end
        n += 1
      end
    end

    assert any_in?(shown, WHITE, 16, 100, 24, 7)
    refute any_in?(shown, WHITE, 40, 100, 60, 7), "nothing past the narrowed area's edge"
  end

  # Six words a row, so every one is on the smallest screen a run plays as (160 by 144).
  def test_many_words_at_once
    shown = screen_after(3) do
      screen :bitmap
      game_loop do
        clear_screen :black
        40.times { |i| draw_text "AB", 8 + ((i % 6) * 24), 8 + ((i / 6) * 16), :white }
        fill_rect 0, 0, 240, 4, :red
      end
    end

    40.times do |i|
      assert any_in?(shown, WHITE, 8 + ((i % 6) * 24), 8 + ((i / 6) * 16), 11, 7), "word #{i} shows"
    end
  end

  def test_a_sprite_moving_over_text
    shown = screen_after(12) do
      screen :bitmap
      image(:dot, "#" => :red) { (["####"] * 4).join("\n") }
      dot = sprite :dot, at: [0, 18]
      clear_screen :black
      draw_text "HELLO WORLD", 16, 16, :white
      game_loop { dot.x += 4 }
    end

    assert any_in?(shown, WHITE, 16, 16, 12, 7), "the letters the sprite has passed show again"
    assert any_in?(shown, WHITE, 60, 16, 20, 7), "the letters the sprite has not reached show"
  end

  def test_black_words_on_a_colour
    shown = screen_after(3) do
      screen :bitmap
      game_loop do
        clear_screen :blue
        draw_text "HELLO", 16, 16, :black
      end
    end

    assert any_in?(shown, BLACK, 16, 16, 30, 7)
  end
end
