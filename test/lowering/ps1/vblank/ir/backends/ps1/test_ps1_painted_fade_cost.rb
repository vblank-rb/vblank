# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a fade on a painted screen costs the PlayStation, read from where Beetle PSX says the time went. A
# game that fades its painted screen draws it by number (PS1::PaintedNumbers), and the graphics chip copies
# the page onto the screen in its colours as each pass ends (Runtime::Paint's rt_paint_numbers_shown): the
# processor sends ten triangles and waits for the chip to draw them. The same work on the processor, a
# colour looked up for every pixel of the page, took it several frames a pass with nothing else to do.
class TestPS1PaintedFadeCost < Minitest::Test
  FADING = VBlank.game("FADE COST", consoles: %i[ps1]) do
    screen :bitmap
    image(:dot, "#" => :white, "." => :red) { Array.new(8) { "#.#.#.#." }.join("\n") }
    level = var :level, 0
    clear_screen :blue
    game_loop do
      repeat(100) { |i| blit :dot, (i * 7) % 300, (i * 3) % 220 }
      level += 3
      level = 0 if level > 100
      fade :black, level
    end
  end

  def test_a_painted_screen_faded_every_pass_keeps_a_frame_a_pass
    rom = FADING.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 20)

    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_operator result.idle_share, :>, 0.6, "the processor was left #{result.idle_share.round(4)} of each frame"
  end
end
