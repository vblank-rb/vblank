# frozen_string_literal: true

require "test_helper"
require "stringio"

# A STATUS BAR'S LETTERS AT PLACES WRITTEN IN THE PROGRAM, on the Super Nintendo. A map word goes to
# video memory in the blank, its address then the word (fullsnes, "SNES PPU Video Memory", VMADD and
# VMDATA), so a letter the game writes in a pass is two words put in the queue of cells the blank
# sends. Where the column and row are written in the program the address is known as the cartridge
# is built, and the letter is those stores, not a call that works the address out again from the
# layer's state. The Color's test of the same game is TestGBCBarLettersCost.
class TestSNESBarLettersCost < Minitest::Test
  LETTERS_A_PASS = 16
  KEY_NAMES = (("A".."Z").to_a + ("a".."z").to_a).freeze
  LETTER_ART = (["#.#.#.#."] * 8).join("\n")
  FRAMES = 30

  # A bar of 48 tiles, writing +letters+ of them a pass along its top row, each by a number read from
  # a table, or with +named+ each by the name of its tile. With +column_kept+ each named letter's
  # column is worked out and kept in a variable first, as a scrolling text keeps where it has reached.
  private def letters_game(letters, named: false, column_kept: false)
    names = KEY_NAMES.first(48)
    art = LETTER_ART
    VBlank.game("BAR #{letters}#{' NAMED' if named}#{' KEPT' if column_kept}", consoles: %i[snes]) do
      screen :tiled
      image(:field_art, "#" => :red, "." => :blue) { art }
      tiles :field_tiles, "#" => :field_art
      looks = names.each_with_index.map do |name, n|
        image(:"letter_#{name}", "#" => :white, "." => :black) { n.even? ? art : art.tr("#.", ".#") }
        :"letter_#{name}"
      end
      tiles :bar_tiles, names.zip(looks).to_h
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      bar = status_bar :bar, tiles: :bar_tiles, map: [names.first * 32, names.first * 32], top: screen_height - 16
      text = table :text, Array.new(64) { |n| (n * 7) % names.length }
      shift = var :shift, 0
      column = var :column, 0
      game_loop do
        letters.times do |col|
          if column_kept
            column.store!((shift + col) & 31)
            next bar.set_tile(column, 0, names[(col * 5) % names.length])
          end
          bar.set_tile col, 0, named ? names[(col * 5) % names.length] : text[(shift + col) & 63]
        end
        shift += 1
      end
    end
  end

  private def awake_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, frames: FRAMES).idle_share
  end

  # THE BUDGET for a letter named in the program: the queued store in the pass, about forty of the
  # processor's cycles, and its address and word sent in the blank, about fifty more, of a frame's
  # 262 lines of 1364 clocks. Called through rt_set_cell, which works the address out from the
  # layer's state, a letter cost two and a half times this.
  MOST_SHARE_A_NAMED_LETTER = 0.0025

  def test_a_letter_named_in_the_program_costs_a_queued_store
    none = awake_share(letters_game(0))
    by_name = (awake_share(letters_game(LETTERS_A_PASS, named: true)) - none) / LETTERS_A_PASS

    assert_operator by_name, :<, MOST_SHARE_A_NAMED_LETTER, "a letter by name costs #{(by_name * 100).round(3)}% of a frame"
  end

  # A letter by a number the game works out is the game's own read of the number, a read of the table
  # of cells, and the same queued store, as on the Color (TestGBCBarLettersCost's budget).
  MOST_TIMES_A_NAMED_LETTER = 2.5

  def test_a_letter_by_number_costs_little_more_than_a_letter_by_name
    none = awake_share(letters_game(0))
    by_number = (awake_share(letters_game(LETTERS_A_PASS)) - none) / LETTERS_A_PASS
    by_name = (awake_share(letters_game(LETTERS_A_PASS, named: true)) - none) / LETTERS_A_PASS

    assert_operator by_number, :<, by_name * MOST_TIMES_A_NAMED_LETTER,
                    "a letter by number costs #{(by_number * 100).round(3)}% of a frame, by name #{(by_name * 100).round(3)}%"
  end

  # A COLUMN KEPT IN A VARIABLE the build proves stays from nought to 31 is read as its low half, and
  # the cell's address is the row's start, known now, plus that column: not the two numbers rt_set_cell
  # takes and works the address out from. Its letters cost little more than those at columns written
  # in the program: the column's own working out and keeping. As the Color's
  # (TestGBCBarLettersCost); through rt_set_cell they cost three and a half times as much.
  MOST_TIMES_A_WRITTEN_COLUMN = 1.35

  def test_a_letter_at_a_column_kept_in_a_variable_costs_little_more_than_one_written
    none = awake_share(letters_game(0))
    written = awake_share(letters_game(LETTERS_A_PASS, named: true)) - none
    kept = awake_share(letters_game(LETTERS_A_PASS, column_kept: true)) - none

    assert_operator kept, :<, written * MOST_TIMES_A_WRITTEN_COLUMN,
                    "#{LETTERS_A_PASS} letters at kept columns cost #{(kept * 100).round(3)}% of a frame, at written ones #{(written * 100).round(3)}%"
  end

  # The letters read off the console in bsnes, the picture held to the interpreter's on every pass.
  def test_the_letters_show_as_the_interpreter_says
    [{ named: false }, { named: true }, { column_kept: true }].each do |shape|
      VBlank::IR::Backends::SNES::CheckedRun.new.run(letters_game(LETTERS_A_PASS, **shape).program(console: :snes), frames: 6)
    end
    pass
  end
end
