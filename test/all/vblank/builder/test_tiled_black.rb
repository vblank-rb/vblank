# frozen_string_literal: true

require "test_helper"

# BLACK DRAWN BY COLOUR ON A BACKGROUND is see-through, unless the tileset says `black: :solid`. A
# tile whose left half is black and right half white, over a red backdrop: the left half shows
# red through it, or stays black.
class TestTiledBlack < Minitest::Test
  RED = 0x001F
  WHITE = 0x7FFF
  BLACK = 0x0000

  private def game(**says)
    b = Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :red
      image(:half, "#" => :black, "." => :white) { (["####...."] * 8).join("\n") }
      tiles :walls, "#" => :half, **says
      background :room, tiles: :walls, map: "#"
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_black_is_see_through_unless_a_tileset_says
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(1, 1)
    assert_equal WHITE, screen.pixel(6, 1)
  end

  def test_a_tileset_can_say_see_through_itself
    assert_equal RED, game_player.run(game(black: :see_through), frames: 3).screen.pixel(1, 1)
  end

  def test_a_tileset_that_says_black_is_solid_keeps_its_black
    screen = game_player.run(game(black: :solid), frames: 3).screen

    assert_equal BLACK, screen.pixel(1, 1)
    assert_equal WHITE, screen.pixel(6, 1)
  end

  # What the picture marks see-through stays so, for a tile with both.
  def test_a_solid_tileset_keeps_what_its_art_marks_see_through
    b = Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :red
      image(:part, "#" => :black, "." => :transparent) { (["####...."] * 8).join("\n") }
      tiles :walls, "#" => :part, black: :solid
      background :room, tiles: :walls, map: "#"
      game_loop { wait_vblank }
    end
    b.finalize_program
    screen = game_player.run(b.program, frames: 3).screen

    assert_equal BLACK, screen.pixel(1, 1)
    assert_equal RED, screen.pixel(6, 1)
  end

  # Two tilesets can answer differently about one picture, and each keeps its own answer.
  def test_two_tilesets_of_one_picture_each_keep_their_answer
    assert_equal RED, game_player.run(two_tilesets_game(:plain), frames: 3).screen.pixel(1, 1)
    assert_equal BLACK, game_player.run(two_tilesets_game(:outlined), frames: 3).screen.pixel(1, 1)
  end

  private def two_tilesets_game(showing)
    b = Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :red
      image(:half, "#" => :black, "." => :white) { (["####...."] * 8).join("\n") }
      tiles :holes, "#" => :half
      tiles :outline, "#" => :half, black: :solid
      room = background :room, tiles: { plain: :holes, outlined: :outline }, map: { plain: "#", outlined: "#" }
      room.show_map showing
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # A BACKGROUND ON A PAINTED SCREEN is stamped into the picture, and black means there what it means
  # on a tiled one: the picture under it stays, unless the tileset says black is solid.
  private def stamped_game(**says)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:half, "#" => :black, "." => :white) { (["####...."] * 8).join("\n") }
      tiles :walls, "#" => :half, **says
      clear_screen :red
      background :room, tiles: :walls, map: "#"
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_stamped_background_keeps_black_see_through_unless_a_tileset_says
    assert_equal RED, game_player.run(stamped_game, frames: 3).screen.pixel(1, 1)
    assert_equal BLACK, game_player.run(stamped_game(black: :solid), frames: 3).screen.pixel(1, 1)
  end

  def test_an_unknown_answer_is_a_friendly_error
    error = assert_raises(ArgumentError) { game(black: :opaque) }

    assert_match(/black: :opaque/, error.message)
    assert_match(/:solid/, error.message)
  end
end
