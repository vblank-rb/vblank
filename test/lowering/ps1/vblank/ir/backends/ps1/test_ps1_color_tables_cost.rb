# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT CHANGING ONE LIST OF COLOURS COSTS A PLAYSTATION, read from where Beetle PSX says the time went. A
# screen drawn from tiles shows everything through colour tables in video RAM, which the runtime works out
# from the game's colours through the fade in force and copies there as the pass's picture is drawn
# (Runtime::Colors). A list told another set changes its own table, so it must work out and copy that table,
# and only the entries its pictures use, not every table on the screen; and a fade must work each colour out
# with no multiply and no call for each.
class TestPS1ColorTablesCost < Minitest::Test
  PASSES = 24

  # A list told the same set every pass: a set already held costs a test (rt_colors_hold). Measured, a few
  # hundred-thousandths of a frame.
  SAME_MOST = 0.0002

  # One list changing every pass, with no fade and with a steady fade toward white. Measured, under a
  # three-hundredth either way: its own table's entries in use walked and copied. Every table walked and
  # copied, a call for each colour, was over a seventieth, and under the fade near a fiftieth.
  ONE_LIST_MOST = 0.005

  # A tint changing every pass: every table in use walked, three halfwords read for each colour from tables
  # worked out once for the tint. Measured, about a hundred and fortieth. A call and three multiplies for each
  # colour was over a seventieth.
  TINT_MOST = 0.01

  def test_a_list_told_the_same_set_costs_a_test
    assert_operator colour_share(four_tables_game("SAME") { recolor :list_2, %i[other], showing: 0 }), :<=, SAME_MOST,
                    "the colours' share of each frame"
  end

  def test_a_list_changing_every_pass_copies_its_own_table
    assert_operator colour_share(one_list_game(faded: false)), :<=, ONE_LIST_MOST, "the colours' share of each frame"
  end

  def test_a_list_changing_under_a_fade_walks_its_own_table
    assert_operator colour_share(one_list_game(faded: true)), :<=, ONE_LIST_MOST, "the colours' share of each frame"
  end

  def test_a_tint_changing_every_pass_walks_each_colour_without_a_multiply
    game = four_tables_game("TINT PASS") { |step| tint :red, (step & 15) * 6 }

    assert_operator colour_share(game), :<=, TINT_MOST, "the colours' share of each frame"
  end

  def test_lists_changed_and_faded_on_different_passes_show_what_the_interpreter_shows
    game_player.run(mixed_game.program(console: :ps1), frames: 40)
  end

  private

  def colour_share(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_(tint|color)/) }.sum(&:share)
  end

  # The third ship's list holds the other set or its own, in turn, every pass; +faded+ with the screen held
  # 40% of the way to white.
  def one_list_game(faded:)
    four_tables_game("LIST #{faded ? 'FADED' : 'PLAIN'}") do |step|
      fade :white, 40 if faded
      recolor :list_2, %i[other], showing: step & 1
    end
  end

  # The third ship's list changing every other pass, the first's every fourth, and the fade toward black
  # every eighth, so some passes change one table, some several, some every one.
  def mixed_game
    four_tables_game("LISTS MIXED") do |step|
      recolor :list_2, %i[other], showing: (step >> 1) & 1
      recolor :list_0, %i[other], showing: (step >> 2) & 1
      fade :black, ((step >> 3) & 3) * 25
    end
  end

  # A background of fifteen colours, and a list of fifteen for each of three ships. +each_pass+ is handed
  # the pass's count.
  def four_tables_game(name, &each_pass)
    VBlank.game(name, consoles: %i[ps1]) do
      screen :tiled
      image :ground, width: 8, height: 8, data: Array.new(64) { |at| rgb((at % 15 % 8) * 4, (at % 15 / 8) * 4, 16) }
      tiles :set, "g" => :ground
      background :field, tiles: :set, map: Array.new(30) { "g" * 40 }
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
