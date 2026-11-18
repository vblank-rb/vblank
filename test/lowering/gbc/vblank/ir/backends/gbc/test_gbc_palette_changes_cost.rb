# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT CHANGING ONE LIST OF COLOURS COSTS A GAME BOY COLOR, measured in the emulator. The cartridge
# keeps a copy of the console's 16 palettes, works out the ones a pass changed as it ends, through the
# fade in force (Runtime::Picture#emit_tint), and sends them in the blank (#emit_palettes_sent). A
# background told other colours for one of its four palettes changes that palette, so it must work out
# and send that one, not every palette in use, and under a fade it must walk that palette's four
# colours, not every colour on the screen.
class TestGBCPaletteChangesCost < Minitest::Test
  PASSES = 24

  # A background told the same colours every pass: the builder writes a change only when the answer
  # changed (Builder#finalize_background_colors), so this costs what a still screen does, a test.
  # Measured, a few ten-thousandths, as on the still screen.
  SAME_MOST = 0.001

  # One of the background's four palettes changing every pass, no fade. Measured, about an eightieth:
  # the palette written, copied and sent. Every palette in use copied and all sixteen sent was over a
  # twentieth.
  ONE_PALETTE_MOST = 0.02

  # The same under a steady fade toward white. Measured, about a fiftieth: that palette's four
  # colours walked. Every colour in use walked again was a tenth.
  ONE_PALETTE_FADED_MOST = 0.04

  def test_a_background_told_the_same_colours_costs_a_still_screen
    assert_operator colour_share(same_colors_game), :<=, SAME_MOST, "the colours' share of each frame"
  end

  def test_one_palette_changing_every_pass_is_sent_alone
    assert_operator colour_share(one_palette_game(faded: false)), :<=, ONE_PALETTE_MOST, "the colours' share of each frame"
  end

  def test_one_palette_changing_under_a_fade_is_walked_alone
    assert_operator colour_share(one_palette_game(faded: true)), :<=, ONE_PALETTE_FADED_MOST, "the colours' share of each frame"
  end

  def test_palettes_changed_and_faded_on_different_passes_show_what_the_interpreter_shows
    game_player.run(mixed_game.program(console: :gbc), frames: 40)
  end

  private

  def colour_share(game)
    rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)

    assert_equal result.frames, result.passes, "every pass fits in one frame"
    result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|background_colors|picture_write_palettes|picture_palette|copy_b)/) }.sum(&:share)
  end

  def same_colors_game
    four_palettes_game("SAME COLORS") { |_step, field| field.draw_with({ own0: :other0 }) }
  end

  # The first palette holds its own colours or the other set, in turn, every pass; +faded+ with the
  # screen held 40% of the way to white.
  def one_palette_game(faded:)
    four_palettes_game("ONE #{faded ? 'FADED' : 'PLAIN'}") do |step, field|
      fade :white, 40 if faded
      field.draw_with({ own0: %i[own0 other0] }, showing: step & 1)
    end
  end

  # The first palette changing every other pass, the third every fourth, and the fade toward black
  # every eighth, so some passes change one, some several, some none.
  def mixed_game
    four_palettes_game("COLORS MIXED") do |step, field|
      field.draw_with({ own0: %i[own0 other0], own2: %i[own2 other2] }, showing: (step >> 1) & 1)
      fade :black, ((step >> 3) & 3) * 25
    end
  end

  # A background of four palettes, a tile drawn from each, and four sprites of their own colours.
  # +each_pass+ is handed the pass's count and the background.
  def four_palettes_game(name, &each_pass)
    VBlank.game(name, consoles: %i[gbc]) do
      screen :tiled
      4.times do |t|
        colors :"own#{t}", [:transparent, rgb(31, t * 6, 0), rgb(0, 31, t * 6), rgb(t * 6, 0, 31)]
        colors :"other#{t}", [:transparent, rgb(t * 6, 31, 9), rgb(9, t * 6, 31), rgb(31, 9, t * 6)]
        image :"tile#{t}", width: 8, height: 8, colors: :"own#{t}", places: Array.new(64) { |i| 1 + ((i / 8) % 3) }
      end
      tiles :set, (0...4).to_h { |t| [t.to_s, :"tile#{t}"] }
      field = background :field, tiles: :set, map: Array.new(18) { "0123" * 5 }
      4.times do |n|
        inks = %w[# o +].each_with_index.to_h { |mark, ink| [mark, rgb(n * 4, ink * 10, 31 - n)] }
        image(:"ship#{n}", **inks, "." => :transparent) { ".#o+#o+.\n" * 8 }
        sprite :"ship_#{n}", at: [8 + (n * 18), 60], facing: { down: :"ship#{n}" }
      end
      step = var :step, 0
      game_loop do
        step += 1
        instance_exec(step, field, &each_pass)
      end
    end
  end
end
