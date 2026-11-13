# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A WHOLE-SCREEN FADE COSTS A GAME BOY COLOR, measured in the emulator. A Color has no blend, so
# a fade is every colour the game shows walked toward black (Runtime::Picture#emit_tint), and a busy
# screen fading out has its amount change every pass, so every colour is walked again every pass.
# The Color has no multiply either, and a walk that multiplied each channel of each colour took
# frames of its own. A Color game of its own time fades in step with the screen, and a VBlank game
# must lose no frame doing the same.
class TestGBCFadePace < Minitest::Test
  # How much of a frame the colours may take on a pass whose fade changed. Measured, under a tenth:
  # each channel of a colour is a byte read from a table worked out once for the fade's amount, where
  # three software multiplies a colour took about a third of the time and dropped a frame in four.
  MOST_OF_A_FRAME = 0.12

  FRAMES = 24

  # Every one of the sixteen lists in use: eight tiles of four colours on the background, and eight
  # sprites of three, the fade's amount changing on every pass.
  FADING = VBlank.game("COLOR FADE PACE", consoles: %i[gbc]) do
    screen :tiled
    8.times do |n|
      data = Array.new(64) { |at| VBlank::Graphics::Color.rgb((4 * n) + (at % 3), 31 - (5 * (at % 3)), 2 + (n * 3)) }
      image :"art#{n}", width: 8, height: 8, data: data
    end
    tiles :set, **(0...8).to_h { |n| [(97 + n).chr, :"art#{n}"] }
    background :field, tiles: :set, map: Array.new(18) { ("a".."h").to_a.cycle.first(20).join }
    ships = Array.new(8) do |n|
      inks = %w[# o +].each_with_index.to_h { |mark, ink| [mark, VBlank::Graphics::Color.rgb(n * 4, ink * 10, 31 - n)] }
      image(:"ship#{n}", **inks, "." => :transparent) { ".#o+#o+.\n" * 8 }
      sprite :"ship_#{n}", at: [8 + (n * 18), 60], facing: { down: :"ship#{n}" }
    end
    level = var :level, 0
    game_loop do
      level += 3
      level = 0 if level > 99
      ships.each_with_index { |ship, n| ship.move_to 8 + (n * 18) + (level & 7), 60 }
      fade :black, level
    end
  end

  def test_the_fading_screen_shows_what_the_interpreter_shows
    game_player.run(FADING.program(console: :gbc), frames: 40)
  end

  def test_a_fade_changing_every_pass_keeps_a_pass_a_frame
    rom = FADING.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: FRAMES)
    colors = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|times)/) }.sum(&:share)

    assert_equal result.frames, result.passes, "every pass fits in one frame"
    assert_operator colors, :<=, MOST_OF_A_FRAME, "the colours take #{(colors * 100).round(1)}% of each frame"
  end
end
