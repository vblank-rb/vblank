# frozen_string_literal: true

require "test_helper"

# `pixelate` in a game of big pixels (`screen :bitmap, pixel_size: 2`): a block is counted in the game's
# pixels, and the biggest is 8, not 16 (Backends::Blocks.largest_for). The console writes the size times
# two into its mosaic register, so it shows the blocks the interpreter does.
class TestBiggerPixelsPixelateOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  private def game(&pixelate)
    VBlank.game("BIGBLOCKS", consoles: %i[gba]) do
      screen :bitmap, pixel_size: 2
      size = var :size, 1
      game_loop do
        (0...8).each { |n| fill_rect n * 15, 0, 15, screen_height, n.even? ? :red : :cyan }
        fill_rect 3, 5, 40, 20, :yellow
        draw_text "HI", 4, 40, :green
        instance_exec(size, &pixelate)
        size += 1
        size = 1 if size > 12
      end
    end
  end

  def test_a_size_written_in_the_program_shows_the_blocks_the_interpreter_shows
    [3, 8].each do |size|
      assert_backends_agree(game { |_| pixelate size }.program, frames: [2, 4], name: "BIGBLOCK#{size}")
    end
  end

  # The game's own size runs on to 12, and the blocks stop growing at 8 in the interpreter and on each build.
  def test_a_size_the_game_works_out_shows_the_blocks_the_interpreter_shows
    assert_backends_agree(game { |size| pixelate size }.program, frames: [2, 5, 9, 12], name: "BIGBLOCKV")
  end

  # A walk out over 14 frames reaches the biggest block, 8, on its last frame, as a walk on a screen of
  # the console's own pixels reaches 16 on its last.
  def test_a_pixelate_out_reaches_the_biggest_block_on_its_last_frame
    game = VBlank.game("BIGWALK", consoles: %i[gba]) do
      screen :bitmap, pixel_size: 2
      pass = var :pass, 0
      biggest_at = var :biggest_at, 0
      game_loop do
        pass += 1
        clear_screen :white
        pixelate_out frames: 14 if pass == 1
        biggest_at = pass if pixelate_size == 8 && biggest_at == 0
      end
    end
    player = game_player
    player.run(game.program, frames: 24)

    assert_operator player[:biggest_at], :>=, 14, "the pass the walk first showed blocks of 8"
  end

  def test_a_size_written_in_the_program_past_the_biggest_is_a_friendly_error
    error = assert_raises(ArgumentError) { game { |_| pixelate 9 }.program }

    assert_match(/from 1 to 8/, error.message)
  end
end
