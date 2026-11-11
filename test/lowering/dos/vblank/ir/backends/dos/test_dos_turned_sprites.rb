# frozen_string_literal: true

require "test_helper"

# A SPRITE OVER THE PICTURE THAT TURNS OR CHANGES SIZE ON A PC, in DOSBox, held to the interpreter on every pass
# (DOS::CheckedRun): no card turns a picture, so the processor does the interpreter's sum a pixel at a time
# (Runtime::Turning). What turning and resizing do is in
# test/console/gba/vblank/builder/test_sprite_over_picture_on_the_advance.rb.
class TestDOSTurnedSprites < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # 8 by 6, no two rows or columns alike, so a turn the wrong way or a pixel off shows.
  ARROW = Array.new(48) do |i|
    column = i % 8
    row = i / 8
    next :red if row.zero?
    next :green if column.zero?

    column == row + 1 ? :white : :blue
  end.freeze

  private def checked(frames:, &game)
    made = VBlank.game("DOSGAME", consoles: %i[dos]) do
      screen :bitmap
      image :arrow, width: 8, height: 6, data: ARROW
      clear_screen :gray
      instance_eval(&game)
    end
    DOS::CheckedRun.new.run(made.program(console: :dos), frames: frames)
  end

  private def color(name) = VBlank::Graphics::Color.resolve(name)

  # The rows of the screen that show the picture's red top row, with the sprite turned +degrees+.
  private def red_rows(degrees)
    run = checked(frames: 4) do
      arrow = sprite :arrow, at: [100, 80], over_picture: true
      arrow.face_angle degrees
      game_loop {}
    end
    (70..100).select { |y| (90..120).any? { |x| run.screen.pixel(x, y) == color(:red) } }
  end

  # Turned half way round, the picture's top row is at its bottom; a quarter, it stands on its side.
  def test_a_sprite_turned_half_way_round_is_the_other_way_up
    upright, on_its_side, upside_down = [0, 90, 180].map { |degrees| red_rows(degrees) }

    assert_equal [1, 1], [upright.size, upside_down.size], "the top row is one row of the screen either way up"
    assert_operator upside_down.first - upright.first, :>=, 5, "a picture six rows high, its top row now its last"
    assert_equal 8, on_its_side.size, "a row eight pixels long stands eight rows high"
  end

  # Every angle there is, both ways round and past a whole turn, at sizes from a quarter to three times,
  # over a picture the game paints, beside a sprite that does not turn.
  def test_a_sprite_that_turns_and_grows_pass_by_pass
    run = checked(frames: 75) do
      arrow = sprite :arrow, at: [100, 80], over_picture: true
      still = sprite :arrow, at: [20, 20], over_picture: true
      passes = var :passes, 0
      game_loop do
        arrow.face_angle (passes * 37) - 500
        arrow.scale passes * 0.04 + 0.25 if passes < 70
        still.x += 1
        draw_rect_at passes * 3, 78, 4, 9, :yellow
        passes += 1
      end
    end

    assert_equal 75, run[:passes]
  end

  # At every edge of the screen, and far enough down that the patch's last rows are counted round to the
  # top of the screen, where the interpreter shows them too.
  def test_turned_sprites_at_the_edges_and_counted_round_past_row_255
    run = checked(frames: 40) do
      left = sprite :arrow, at: [-6, 90], over_picture: true
      right = sprite :arrow, at: [316, 40], over_picture: true
      top = sprite :arrow, at: [150, -5], over_picture: true
      low = sprite :arrow, at: [200, 150], over_picture: true
      passes = var :passes, 0
      game_loop do
        left.turn 7
        right.turn(-11)
        top.turn 13
        low.turn 5
        low.scale 2.0
        low.y += 4
        passes += 1
      end
    end

    assert_equal 310, run.sprites.last.y
  end
end
