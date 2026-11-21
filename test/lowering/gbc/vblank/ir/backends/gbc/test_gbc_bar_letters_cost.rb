# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "digest"

# A status bar's letters written by numbers the game works out, on the Color. A game whose text
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

  # The budget: a letter by number is the game's own read of the number, a read of the table of
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

  # A port's text, read from its data pack at places written in the program. A cartridge is built with
  # the player's copy read, so every number of the pack is known as it is built: `text[3]` is one
  # tile, and the letter costs what a letter named in the program costs, with no table read. A
  # number standing for no tile (0xFF here) writes nothing either way.
  PACK_TEXT = Array.new(LETTERS_A_PASS) { |n| n % 5 == 4 ? 0xFF : (n * 7) % 48 }.freeze

  private def pack_text_original(folder)
    copy = PACK_TEXT.pack("C*")
    path = File.join(folder, "made_up_text.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The bar's top row written a letter a line, each from PACK_TEXT through the pack, or with +named+
  # by the name of the same tile; +letters+ nought writes none.
  # With +column_kept+ each letter's column is worked out and kept in a variable first, as a
  # scrolling text keeps where it has reached.
  private def pack_letters_game(folder, letters, named: false, column_kept: false)
    from = pack_text_original(folder)
    names = KEY_NAMES.first(48)
    art = LETTER_ART
    numbers = PACK_TEXT
    VBlank.game("PACK BAR #{letters}#{' NAMED' if named}#{' KEPT' if column_kept}", consoles: %i[gbc]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.numbers :text, count: numbers.length, width: :byte, signed: false
        slots.fill_from_copy { |copy, filled| repeat(numbers.length) { |at| filled[:text][at] = copy.byte(at) } }
      end
      image(:field_art, "#" => :red, "." => :blue) { art }
      tiles :field_tiles, "#" => :field_art
      looks = names.each_with_index.map do |name, n|
        image(:"letter_#{name}", "#" => :white, "." => :black) { n.even? ? art : art.tr("#.", ".#") }
        :"letter_#{name}"
      end
      tiles :bar_tiles, names.zip(looks).to_h
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      bar = status_bar :bar, tiles: :bar_tiles, map: [names.first * 32, names.first * 32], top: screen_height - 16
      text = table :text, pack[:text]
      place = var :place, 0
      column = var :column, 0
      game_loop do
        letters.times do |col|
          if column_kept
            column.store!((place + col) & 0xFF)
            next bar.set_tile(column, 0, text[col])
          end
          next bar.set_tile(col, 0, text[col]) unless named

          bar.set_tile(col, 0, names[numbers[col]]) if numbers[col] < names.length
        end
      end
    end
  end

  def test_a_letter_read_from_the_pack_at_a_written_place_costs_a_letter_named
    Dir.mktmpdir do |folder|
      none = awake_share(pack_letters_game(folder, 0))
      by_number = awake_share(pack_letters_game(folder, LETTERS_A_PASS)) - none
      by_name = awake_share(pack_letters_game(folder, LETTERS_A_PASS, named: true)) - none

      assert_in_delta by_name, by_number, 0.001,
                      "#{LETTERS_A_PASS} letters from the pack cost #{(by_number * 100).round(3)}% of a frame, named #{(by_name * 100).round(3)}%"
    end
  end

  # A column kept in a variable the build proves stays in a byte is read as that byte, as a column
  # ANDed with 0xFF is: the cell's place is the row's start plus that byte, not the four numbers the
  # general routine takes. Its letters cost little more than those at columns written in the program:
  # the column's own working out and keeping. Through the general routine they cost more than twice as much.
  MOST_TIMES_A_WRITTEN_COLUMN = 1.35

  def test_a_letter_at_a_column_kept_in_a_variable_costs_little_more_than_one_written
    Dir.mktmpdir do |folder|
      none = awake_share(pack_letters_game(folder, 0))
      written = awake_share(pack_letters_game(folder, LETTERS_A_PASS)) - none
      kept = awake_share(pack_letters_game(folder, LETTERS_A_PASS, column_kept: true)) - none

      assert_operator kept, :<, written * MOST_TIMES_A_WRITTEN_COLUMN,
                      "#{LETTERS_A_PASS} letters at kept columns cost #{(kept * 100).round(3)}% of a frame, at written ones #{(written * 100).round(3)}%"
    end
  end
end
