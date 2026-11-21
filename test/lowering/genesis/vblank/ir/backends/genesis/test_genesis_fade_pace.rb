# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a whole-screen fade costs a Genesis, measured in the emulator. A busy screen fading has its
# amount change every pass, so every colour the game uses is worked out again every pass
# (Runtime::Tint). A Genesis game of its own time that fades a frame at a time moves each of its
# colours a step with a compare and an add a channel and writes the palette back, about a hundred
# cycles a colour (the 68000's timing table), and a VBlank game fading must lose no frame doing the
# same.
class TestGenesisFadePace < Minitest::Test
  # How much of a frame the colours may take when every pass changes the fade, on a screen of four
  # full palette lines. Measured, about three fortieths: the walk's tables worked out once a pass, a
  # colour three table reads from channels noted when the game set it, and the lines copied. Each
  # colour taken apart again on every pass and each table entry shifted into place took an eighth.
  MOST_OF_A_FRAME = 0.085

  PASSES = 24

  # Sixty colours, a background tile of fifteen and three sprites drawn with lists of fifteen each, the
  # walk +each_pass+ asks for given the pass's level, which moves by 7%, more than one of a fade's steps
  # (FadeSteps), on every pass.
  def self.walking(name, &each_pass)
    VBlank.game(name, consoles: %i[genesis]) do
      screen :tiled
      image :ground, width: 8, height: 8, data: Array.new(64) { |at| rgb((at % 15 % 8) * 4, (at % 15 / 8) * 4, 16) }
      tiles :set, "g" => :ground
      background :field, tiles: :set, map: Array.new(20) { "g" * 30 }
      ships = Array.new(3) do |list|
        colors :"list_#{list}", [:transparent, *Array.new(15) { |at| rgb((at % 8) * 4, list * 8, ((at / 8) * 4) + 4) }]
        image :"ship_#{list}", width: 8, height: 8, places: Array.new(64) { |at| 1 + (at % 15) }, colors: :"list_#{list}"
        sprite(:"ship_#{list}", at: [40 + (list * 30), 60]).tap { |ship| ship.draw_with :"list_#{list}" }
      end
      level = var :level, 0
      game_loop do
        level += 7
        level = 0 if level > 99
        ships.each_with_index { |ship, n| ship.move_to 40 + (n * 30) + (level & 7), 60 }
        instance_exec(level, &each_pass)
      end
    end
  end

  FADING = walking("FADE PACE") { |level| fade :black, level }
  WHITENING = walking("FADE PACE WHITE") { |level| fade :white, level }
  TINTING = walking("TINT PACE") { |level| tint :orange, level }

  def test_the_fading_screen_shows_what_the_interpreter_shows
    game_player.run(FADING.program(console: :genesis), frames: 40)
  end

  def test_the_screen_fading_to_white_shows_what_the_interpreter_shows
    game_player.run(WHITENING.program(console: :genesis), frames: 40)
  end

  def test_the_tinted_screen_shows_what_the_interpreter_shows
    game_player.run(TINTING.program(console: :genesis), frames: 40)
  end

  def test_a_fade_changing_every_pass_takes_a_small_part_of_each_frame
    rom = FADING.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)
    colors = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|colors)/) }.sum(&:share)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    assert_operator colors, :<=, MOST_OF_A_FRAME, "the colours take #{(colors * 100).round(1)}% of each frame"
  end
end
