# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a fade toward white or a colour costs a Super Nintendo when its amount changes every pass,
# measured in the emulator. A fade to black is the display's own brightness and moves no colour, but
# toward white or a colour every colour the pictures show is moved again every pass (Runtime::Tint):
# the walk's tables worked out once, then each colour three table reads put together.
class TestSNESFadePace < Minitest::Test
  PASSES = 24

  # The colour routines' share of a frame with the fade changing every pass, on a screen of four
  # palettes of fifteen colours. Measured, under a fifth: the tables filled by adding one value to
  # the next, and each colour's three words read at indexes one mask of the colour gives. A multiply
  # for each table value and each channel shifted out of the colour and back in was over half a frame.
  MOST_OF_A_FRAME = 0.22

  # Sixty colours, a background tile of fifteen and three sprites drawn with lists of fifteen each, the
  # walk +each_pass+ asks for given the pass's level, which moves by 7%, more than one of a fade's steps
  # (FadeSteps), on every pass.
  def self.walking(name, &each_pass)
    VBlank.game(name, consoles: %i[snes]) do
      screen :tiled
      image :ground, width: 8, height: 8, data: Array.new(64) { |at| rgb((at % 15 % 8) * 4, (at % 15 / 8) * 4, 16) }
      tiles :set, "g" => :ground
      background :field, tiles: :set, map: Array.new(28) { "g" * 32 }
      ships = Array.new(3) do |list|
        colors :"list_#{list}", [:transparent, *Array.new(15) { |at| rgb(at * 2, list * 8, 31 - (at * 2)) }]
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

  WHITENING = walking("FADE PACE WHITE") { |level| fade :white, level }
  TINTING = walking("TINT PACE") { |level| tint :orange, level }
  UNDIMMED_BLACK = walking("FADE PACE BLACK") { |level| tint :black, level }

  def test_the_screen_fading_to_white_shows_what_the_interpreter_shows
    game_player.run(WHITENING.program(console: :snes), frames: 40)
  end

  def test_the_tinted_screen_shows_what_the_interpreter_shows
    game_player.run(TINTING.program(console: :snes), frames: 40)
  end

  def test_the_screen_tinted_toward_black_shows_what_the_interpreter_shows
    game_player.run(UNDIMMED_BLACK.program(console: :snes), frames: 40)
  end

  def test_a_fade_toward_white_changing_every_pass_takes_a_small_part_of_each_frame
    assert_operator colour_share(WHITENING), :<=, MOST_OF_A_FRAME
  end

  def test_a_tint_changing_every_pass_takes_a_small_part_of_each_frame
    assert_operator colour_share(TINTING), :<=, MOST_OF_A_FRAME
  end

  private

  def colour_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, settle: 10, frames: PASSES)
    share = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|colors)/) }.sum(&:share)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    assert_operator share, :>, 0, "the colours were moved"
    share
  end
end
