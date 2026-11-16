# frozen_string_literal: true

require "test_helper"

# FORTY PIECES OF SPRITES ON THE SCREEN. The Color's sprite table holds forty entries, and each is
# one 8×8 piece of a sprite, so a 16×16 sprite takes four. The table is filled front-most first, so
# with more pieces than that on the screen the ones furthest back find it full and are not drawn
# at all, on any line. The lines here are never crowded (ten pieces a line at most), so only the
# table's size leaves anything out.
class TestFortySpritePiecesOnTheColor < Minitest::Test
  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)

  private def program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red square furthest back (declared first, so every other is drawn over it), then +bars+
  # green bars of two pieces each, five to a band of eight lines: ten pieces on a line at most.
  private def square_behind_bars(bars)
    program do
      screen :tiled
      image(:red_square, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_bar, "g" => :green) { (["g" * 16] * 8).join("\n") }
      sprite :red_square, at: [140, 130]
      bars.times { |i| sprite :green_bar, at: [(i % 5) * 20, (i / 5) * 8] }
      game_loop {}
    end
  end

  def test_the_forty_first_piece_is_left_out
    screen = game_player.run(square_behind_bars(20), frames: 3).screen

    refute_equal RED, screen.pixel(143, 133), "the red square is the forty-first piece in the table"
    assert_equal GREEN, screen.pixel(3, 3), "the first green bar is drawn"
    assert_equal GREEN, screen.pixel(91, 27), "and the last"
  end

  def test_forty_pieces_are_all_drawn
    screen = game_player.run(square_behind_bars(19), frames: 3).screen

    assert_equal RED, screen.pixel(143, 133), "the red square is the thirty-ninth piece, so the table holds it"
  end

  # Eleven 16×16 things in a pool, four to a band of forty lines: forty-four pieces, eight on a line
  # at most. Ten things fill the table, and one is not drawn.
  def test_eleven_big_things_show_ten
    game = program do
      screen :tiled
      image(:block, "#" => :red) { (["#" * 16] * 16).join("\n") }
      crowd = pool :crowd, x: 0, y: 0, capacity: 11, image: :block
      11.times { |i| crowd.spawn(x: (i % 4) * 40, y: (i / 4) * 40) }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    shown = (0...11).count { |i| screen.pixel(((i % 4) * 40) + 8, ((i / 4) * 40) + 8) == RED }
    assert_equal 10, shown
  end

  # Thirty-two 16×16 things moving down a line each frame, so the crowded lines and the table's
  # last entries change every frame, drawn in the pool's order and in the order of their places.
  # Some stand off the right of the screen and below it, and take no entry.
  def test_a_moving_crowd_of_big_things
    block = (["#" * 16] * 16).join("\n")
    [false, true].each do |ordered|
      game = program do
        screen :tiled
        image(:block, "#" => :red) { block }
        crowd = pool :crowd, x: 0, y: 0, capacity: 32, image: :block
        draw_in_order(crowd) if ordered
        32.times { |i| crowd.spawn(x: (i * 13) % 200, y: (i * 37) % 120) }
        game_loop { crowd.each { |c| c.y = (c.y + 1) & 127 } }
      end
      screen = game_player.run(game, frames: 6).screen

      red = (0...144).step(4).any? { |y| (0...160).step(4).any? { |x| screen.pixel(x, y) == RED } }
      assert red, "the crowd is drawn (ordered: #{ordered})"
    end
  end
end
