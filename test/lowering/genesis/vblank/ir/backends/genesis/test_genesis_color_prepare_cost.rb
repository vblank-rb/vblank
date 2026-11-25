# frozen_string_literal: true

require "test_helper"
require "stringio"

# What preparing the colours costs a Genesis on a pass that changes few of them or none, measured in the
# emulator. The cartridge works the colour memory out in work RAM as a pass ends and copies it to the video
# chip in the blank (Runtime::Tint). A Genesis game of its own time writes a palette line only when a fade
# or an effect changes it, so a VBlank game must spend nothing on a pass that changed no colour, and on a
# pass that changed one line, that line's work and not the other three's.
class TestGenesisColorPrepareCost < Minitest::Test
  PASSES = 24

  # The colour routines' share of a frame on a pass that changed no colour: the test that finds nothing
  # owed, and the same test in the blank. Measured, about a thousandth: a list told the set it holds
  # already and a fade told the amount in force do nothing (rt_colors_hold, rt_tint_to).
  STILL_MOST = 0.002

  # What one line of four changing every pass may cost, against all four changing every pass under a
  # fade. Measured, about a third: one line's fifteen colours taken apart and worked out and one line
  # copied, against four lines read from their noted channels and the walk's tables. All four lines
  # worked out and copied again for one is more than the fade.
  ONE_LINE_OF_FADING_MOST = 0.45

  def test_a_pass_that_changes_no_colour_spends_nothing_preparing_them
    assert_operator colour_share(still_game), :<=, STILL_MOST, "the colours' share of each frame"
  end

  def test_a_pass_that_changes_one_line_works_out_that_line_alone
    one_line = colour_share(one_line_game)
    fading = colour_share(fading_game)

    assert_operator one_line, :<=, fading * ONE_LINE_OF_FADING_MOST,
                    "one line changing took #{(one_line * 100).round(2)}% of a frame, a fade of four #{(fading * 100).round(2)}%"
  end

  def test_lines_changed_and_faded_on_different_passes_show_what_the_interpreter_shows
    game_player.run(mixed_game.program(console: :genesis), frames: 40)
  end

  private

  # The share of each frame the colour routines took, over PASSES passes.
  def colour_share(game)
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|colors|backdrop)/) }.sum(&:share)
  end

  # Every pass tells the third ship's list the set it holds already and the screen the fade in force.
  def still_game
    four_lines_game("COLORS STILL") do |_step|
      recolor :list_2, %i[other], showing: 0
      fade :black, 0
    end
  end

  # Every pass the third ship's list holds the other set or its own, in turn: one line of four changes.
  def one_line_game = four_lines_game("COLORS ONE LINE") { |step| recolor :list_2, %i[other], showing: step & 1 }

  # Every pass the fade's amount changes, by more than one of its steps (FadeSteps): every colour changes.
  def fading_game = four_lines_game("COLORS FADING") { |step| fade :black, (step & 7) * 12 }

  # The list changing every other pass and the fade every fourth, so some passes change one, some both,
  # some neither.
  def mixed_game
    four_lines_game("COLORS MIXED") do |step|
      recolor :list_2, %i[other], showing: (step >> 1) & 1
      fade :black, ((step >> 2) & 3) * 20
    end
  end

  # Four palette lines of fifteen colours each: the background's, and a list for each of three ships, each a
  # colour the console shows exactly. +each_pass+ is handed the pass's count.
  def four_lines_game(name, &each_pass)
    VBlank.game(name, consoles: %i[genesis]) do
      screen :tiled
      image :ground, width: 8, height: 8, data: Array.new(64) { |at| rgb((at % 15 % 8) * 4, (at % 15 / 8) * 4, 16) }
      tiles :set, "g" => :ground
      background :field, tiles: :set, map: Array.new(20) { "g" * 30 }
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
