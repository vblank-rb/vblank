# frozen_string_literal: true

require "test_helper"
require "stringio"

# What drawing a whole tiled screen costs a PlayStation pass, read from where Beetle PSX says the time
# went. The runtime draws every pass whole (Runtime::Tiles): four backgrounds that each fill the screen
# and scroll, and the most sprites the console's description allows. The graphics chip fills every
# pixel of each background, reading each from a plane of 4-bit places in a colour table (PlaneColors),
# a quarter of what it reads from a plane of 15-bit colours: the wait was half a frame with those, and
# is under a third with these. The commands go to it in a list by DMA (Runtime::DrawList), each background
# as soon as it is in the list, and the processor waits only for the chip to finish the pass's picture
# before it is shown (the list's waits), so that wait is where the chip's time shows. The pass must
# still take one frame.
#
# The picture is drawn at the pass's end from where the pass left everything, and shown at the next
# blank, so the chip's drawing cannot run beside the next pass's work without the picture showing a
# frame later than it does: the wait is the chip's own time, less what the processor builds beside it.
class TestPS1TiledScreenCost < Minitest::Test
  BACKGROUNDS = 4
  SPRITES = VBlank::Console::PLAYSTATION.sprites
  CHIP_WAIT = /\Art_(draw_list_\w+_wait|gp0_port_word_wait)\z/

  # The game, its tiles checks of a colour and +gap+ (:transparent, or a colour that hides what is behind).
  def self.full_screen(gap)
    VBlank.game("TILE COST", consoles: %i[ps1]) do
      screen :tiled
      colors = %i[red green blue yellow]
      image(:ball, "#" => :white) { Array.new(16, "#" * 16).join("\n") }
      fields = Array.new(BACKGROUNDS) do |i|
        image(:"tile#{i}", "#" => colors[i], "." => gap) { Array.new(8) { |row| row.even? ? "#.#.#.#." : ".#.#.#.#" }.join("\n") }
        tiles :"set#{i}", "#" => :"tile#{i}"
        background :"field#{i}", tiles: :"set#{i}", map: Array.new(32) { "#" * 32 }
      end
      balls = Array.new(SPRITES) { |i| sprite :ball, at: [(i * 37) % 300, (i * 23) % 220] }
      game_loop do
        fields.each_with_index { |field, i| field.scroll_by i + 1, 1 }
        balls.first.x += 1
      end
    end
  end

  SEE_THROUGH = full_screen(:transparent)
  # Every background draws every pixel, so the front one hides the rest, which are not drawn (Runtime::Tiles).
  SOLID = full_screen(:gray)

  def test_four_scrolling_backgrounds_and_every_sprite_take_one_frame
    wait = chip_wait(SEE_THROUGH)

    assert_operator wait, :<, 0.34, "the processor waited on the graphics chip for #{wait.round(4)} of each frame"
  end

  # Only the front background is drawn: about a quarter of the four.
  def test_backgrounds_hidden_behind_one_that_draws_every_pixel_are_not_drawn
    wait = chip_wait(SOLID)

    assert_operator wait, :<, 0.08, "the processor waited on the graphics chip for #{wait.round(4)} of each frame"
  end

  # The share of each frame the processor waited on the graphics chip, playing +game+ for 20 frames, each
  # pass of which must take one.
  private def chip_wait(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 20)

    assert_equal({ 1 => 20 }, result.passes_by_frames)
    result.runtime.select { |spent| spent.routine.to_s.match?(CHIP_WAIT) }.sum(&:share)
  end
end
