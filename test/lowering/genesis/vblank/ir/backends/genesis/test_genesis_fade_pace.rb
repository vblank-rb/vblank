# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A WHOLE-SCREEN FADE COSTS A GENESIS, measured in the emulator. A busy screen fading out has
# its amount change every pass, so every colour the game uses is worked out again every pass
# (Runtime::Tint). A Genesis game of its own time steps its sixty-odd colours a frame for a few
# hundredths of a frame, and a VBlank game fading must lose no frame doing the same.
class TestGenesisFadePace < Minitest::Test
  # How much of a frame the colours may take on a pass whose fade changed. Measured, about a twentieth:
  # each channel of a colour is a word read from a table worked out once for the fade's amount, not
  # three multiplies for each colour.
  MOST_OF_A_FRAME = 0.06

  PASSES = 24

  # Forty-two colours: nine tiles of four on the background, and three sprites of six more, the
  # fade's amount changing on every pass.
  FADING = VBlank.game("FADE PACE", consoles: %i[genesis]) do
    screen :tiled
    9.times do |n|
      data = Array.new(64) { |at| VBlank::Graphics::Color.rgb((8 * (n % 4)) + (at % 4), (8 * (n / 4)) + 2, 5 + (n * 2)) }
      image :"art#{n}", width: 8, height: 8, data: data
    end
    tiles :set, **(0...9).to_h { |n| [(97 + n).chr, :"art#{n}"] }
    background :field, tiles: :set, map: Array.new(20) { ("a".."i").to_a.cycle.first(30).join }
    %i[red green blue].each_with_index do |base, n|
      image :"ship#{n}", width: 8, height: 8, data: Array.new(64) { |at| %i[yellow white cyan].push(base).fetch(at % 4) }
    end
    ships = Array.new(3) { |n| sprite :"ship_#{n}", at: [40 + (n * 30), 60], facing: { down: :"ship#{n}" } }
    level = var :level, 0
    game_loop do
      level += 3
      level = 0 if level > 99
      ships.each_with_index { |ship, n| ship.move_to 40 + (n * 30) + (level & 7), 60 }
      fade :black, level
    end
  end

  def test_the_fading_screen_shows_what_the_interpreter_shows
    game_player.run(FADING.program(console: :genesis), frames: 40)
  end

  def test_a_fade_changing_every_pass_takes_a_small_part_of_each_frame
    rom = FADING.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)
    colors = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|colors)/) }.sum(&:share)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    assert_operator colors, :<=, MOST_OF_A_FRAME, "the colours take #{(colors * 100).round(1)}% of each frame"
  end
end
