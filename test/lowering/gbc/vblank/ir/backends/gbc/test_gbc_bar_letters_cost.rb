# frozen_string_literal: true

require "test_helper"
require "stringio"

# A STATUS BAR'S LETTERS WRITTEN BY NUMBERS THE GAME WORKS OUT, on the Color. A game whose text
# is not known when it is built (read from a table, or from a data pack) writes each letter with
# `bar.set_tile col, row, number`, the number counting through the bar's tileset keys. The
# console's own games put a letter in the window's map as one byte worked out with an add (Pan
# Docs, "VRAM Tile Maps": a map entry is the tile's number), so what a letter costs must not grow
# with how many tiles the bar has: the Color reads the cell from a table by the number, as it does
# for `set_cell` (TestGBCToldCellsCost), rather than testing the number against every key.
class TestGBCBarLettersCost < Minitest::Test
  LETTERS_A_PASS = 16
  KEY_NAMES = (("A".."Z").to_a + ("a".."z").to_a).freeze
  LETTER_ART = (["#.#.#.#."] * 8).join("\n")

  # A bar of +keys+ tiles, writing +letters+ of them a pass, each by a number read from a table, or
  # with +named+ each by the name of its tile.
  private def letters_game(keys, letters, named: false)
    names = KEY_NAMES.first(keys)
    art = LETTER_ART
    VBlank.game("BAR #{keys} #{letters}#{' NAMED' if named}", consoles: %i[gbc]) do
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
      text = table :text, Array.new(64) { |n| (n * 7) % keys }
      shift = var :shift, 0
      game_loop do
        letters.times { |col| bar.set_tile col, 0, named ? names[col % keys] : text[(shift + col) & 63] }
        shift += 1
      end
    end
  end

  private def awake_share(game)
    1 - game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 30).idle_share
  end

  def test_a_letter_costs_the_same_however_many_tiles_the_bar_has
    few = awake_share(letters_game(4, LETTERS_A_PASS))
    many = awake_share(letters_game(48, LETTERS_A_PASS))

    assert_in_delta few, many, 0.005, "#{LETTERS_A_PASS} letters from 48 tiles cost #{(many - few).round(4)} of a frame more than from 4"
  end

  # THE BUDGET: a letter by number is the game's own read of the number, a read of the table of
  # cells and the cell written, so it costs at most this many times a letter named in the program,
  # which is the cell written alone. Written as tests of the number against each of 48 keys, a
  # letter cost four times one named.
  MOST_TIMES_A_NAMED_LETTER = 2.5

  def test_a_letter_by_number_costs_little_more_than_a_letter_by_name
    none = awake_share(letters_game(48, 0))
    by_number = (awake_share(letters_game(48, LETTERS_A_PASS)) - none) / LETTERS_A_PASS
    by_name = (awake_share(letters_game(48, LETTERS_A_PASS, named: true)) - none) / LETTERS_A_PASS

    assert_operator by_number, :<, by_name * MOST_TIMES_A_NAMED_LETTER,
                    "a letter by number costs #{(by_number * 100).round(3)}% of a frame, by name #{(by_name * 100).round(3)}%"
  end
end
