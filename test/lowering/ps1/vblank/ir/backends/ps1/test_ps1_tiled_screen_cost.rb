# frozen_string_literal: true

require "test_helper"
require "stringio"

# What drawing a whole tiled screen costs a PlayStation pass, read from where Beetle PSX says the time
# went. The runtime draws every pass whole (Runtime::Tiles): four backgrounds that each fill the screen
# and scroll, and the most sprites the console's description allows. The graphics chip fills every
# pixel of each background, and the processor waits for room in its queue meanwhile (rt_gp0_word_wait),
# so that wait is where the chip's time shows. The pass must still take one frame.
class TestPS1TiledScreenCost < Minitest::Test
  BACKGROUNDS = 4
  SPRITES = VBlank::Console::PLAYSTATION.sprites
  CHIP_WAIT = /\Art_gp0_word_wait\z/

  FULL_SCREEN = VBlank.game("TILE COST", consoles: %i[ps1]) do
    screen :tiled
    colors = %i[red green blue yellow]
    image(:ball, "#" => :white) { Array.new(16, "#" * 16).join("\n") }
    fields = Array.new(BACKGROUNDS) do |i|
      image(:"tile#{i}", "#" => colors[i], "." => :transparent) { Array.new(8) { |row| row.even? ? "#.#.#.#." : ".#.#.#.#" }.join("\n") }
      tiles :"set#{i}", "#" => :"tile#{i}"
      background :"field#{i}", tiles: :"set#{i}", map: Array.new(32) { "#" * 32 }
    end
    balls = Array.new(SPRITES) { |i| sprite :ball, at: [(i * 37) % 300, (i * 23) % 220] }
    game_loop do
      fields.each_with_index { |field, i| field.scroll_by i + 1, 1 }
      balls.first.x += 1
    end
  end

  def test_four_scrolling_backgrounds_and_every_sprite_take_one_frame
    rom = FULL_SCREEN.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 20)
    wait = result.runtime.select { |spent| spent.routine.to_s.match?(CHIP_WAIT) }.sum(&:share)

    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_operator wait, :<, 0.6, "the processor waited on the graphics chip for #{wait.round(4)} of each frame"
  end
end
