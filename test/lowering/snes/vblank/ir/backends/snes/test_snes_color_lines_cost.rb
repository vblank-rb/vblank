# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT CHANGING ONE LIST OF COLOURS COSTS A SUPER NINTENDO, measured in the emulator. The cartridge keeps
# the colour memory's 512 bytes in work RAM and sends them in the blank (Runtime::Tint). A list told
# other colours changes one palette of sixteen, so it must send that palette and not the 512 bytes, and
# under a fade in force it must move that palette's colours through the fade and not every colour on
# the screen with the fade worked out again.
class TestSNESColorLinesCost < Minitest::Test
  PASSES = 24

  # The colour routines' share of a frame with one list changing every pass, no fade. Measured, under
  # a fiftieth: the list's fifteen colours written and its palette sent. All 512 bytes sent was more.
  ONE_LINE_MOST = 0.024

  # The same with a fade toward white in force. Measured, about a twelfth: the list's colours moved
  # through the fade as it is. The fade worked out again and every colour moved was over half a frame.
  ONE_LINE_FADED_MOST = 0.12

  def test_a_list_changing_every_pass_sends_its_own_palette
    assert_operator colour_share(one_line_game(faded: false)), :<=, ONE_LINE_MOST, "the colours' share of each frame"
  end

  def test_a_list_changing_under_a_fade_moves_its_own_palette
    assert_operator colour_share(one_line_game(faded: true)), :<=, ONE_LINE_FADED_MOST, "the colours' share of each frame"
  end

  def test_lists_changed_and_faded_on_different_passes_show_what_the_interpreter_shows
    game_player.run(mixed_game.program(console: :snes), frames: 40)
  end

  private

  def colour_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, settle: 10, frames: PASSES)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|colors|backdrop)/) }.sum(&:share)
  end

  # The third ship's list holds the other set or its own, in turn, every pass; +faded+ with the screen
  # held 40% of the way to white.
  def one_line_game(faded:)
    four_palettes_game("LINE #{faded ? 'FADED' : 'PLAIN'}") do |step|
      fade :white, 40 if faded
      recolor :list_2, %i[other], showing: step & 1
    end
  end

  # The list changing every other pass and the fade toward white every fourth, so some passes change
  # one, some both, some neither.
  def mixed_game
    four_palettes_game("LINES MIXED") do |step|
      recolor :list_2, %i[other], showing: (step >> 1) & 1
      fade :white, ((step >> 2) & 3) * 20
    end
  end

  # Four palettes of fifteen colours each: the background's, and a list for each of three ships.
  # +each_pass+ is handed the pass's count.
  def four_palettes_game(name, &each_pass)
    VBlank.game(name, consoles: %i[snes]) do
      screen :tiled
      image :ground, width: 8, height: 8, data: Array.new(64) { |at| rgb((at % 15 % 8) * 4, (at % 15 / 8) * 4, 16) }
      tiles :set, "g" => :ground
      background :field, tiles: :set, map: Array.new(28) { "g" * 32 }
      3.times do |list|
        colors :"list_#{list}", [:transparent, *Array.new(15) { |at| rgb((at % 8) * 4, list * 8, ((at / 8) * 4) + 4) }]
        image :"ship_#{list}", width: 8, height: 8, places: Array.new(64) { |at| 1 + (at % 15) }, colors: :"list_#{list}"
        sprite(:"ship_#{list}", at: [40 + (list * 30), 60]).draw_with :"list_#{list}"
      end
      colors :other, [:transparent, *Array.new(15) { |at| rgb((at % 8) * 4, 28, ((at / 8) * 4) + 4) }]
      step = var :step, 0
      game_loop do
        step += 1
        instance_exec(step, &each_pass)
      end
    end
  end
end
