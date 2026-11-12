# frozen_string_literal: true

module VBlank
  module DSL
    # THE CELLS A BACKGROUND FROM THE DATA PACK MAY BE WRITTEN LATER, each as a cell number in the
    # map's layout (`background ..., set_cells:`, then Background#set_cell): the original's own on
    # a map in its console's layout, or the record's (Original::MapCell) on a map of map cells.
    #
    # A retail game puts words on a screen by storing font cells in the map its picture is in: the
    # font's tiles sit in video memory beside the picture's, and no cell of the map names one until
    # the game writes it. A background from the pack is built from the cells its map holds
    # (Builder::PackBackgrounds), so it is told the other cells it may be written, and the build
    # makes their pictures too.
    #
    # +format+ is the layout of a cell number (Console::MapWordFormat), +side+ how many tiles a
    # cell is across, and +tiles_by_word+ each told number to its tiles' keys in the background's
    # tileset, row by row. A number is kept and looked up by the bits the layout reads, so two
    # numbers that differ only in a bit the console keeps for itself (the Genesis's priority) are
    # one cell.
    PackCells = Data.define(:format, :side, :tiles_by_word) do
      # +word+ with the bits the layout does not read cleared (Console::MapWordFormat#read_bits).
      def read_part(word) = word & format.read_bits

      # The tileset keys of the cell +word+ stands for, or nil for a number not told.
      def tiles_of(word) = tiles_by_word[read_part(word)]

      # Is the layout VBlank's own record (Original::MapCell), a map of map cells?
      def map_cells? = format == Original::MapCell::FORMAT

      # The highest number a told cell can be: the record's on a map of map cells, and two bytes on
      # a map in the layout of the original's console.
      def most_number = map_cells? ? Original::MapCell::MOST_NUMBER : 0xFFFF

      # +cell+ as a number in the layout: a number as given, and an Original::MapCell::Cell as the
      # record's number, which only a map of map cells reads. A Cell's tile may be a value the game
      # works out, and the number is then one too. +name+ is the background's.
      def number_of!(cell, name)
        return cell unless cell.is_a?(Original::MapCell::Cell)

        unless map_cells?
          raise ArgumentError, "background :#{name} was given a map cell (#{cell.inspect}), and its map: is a slot of " \
                               "numbers in the layout of the original's console. Only a map of map cells takes a map " \
                               "cell. To fix this, give the cell as a number in that layout, or give map: a slot of map " \
                               "cells."
        end
        Original::MapCell.refuse_oversized_part!("background :#{name} was given a map cell with", tile: cell.tile, bank: cell.bank)
        cell.number
      end

      # WRITE THE CELL at +col+ and +row+ of +background+ as +word+, a number in the layout or an
      # Original::MapCell::Cell on a map of map cells (#number_of!). A cell is +side+ tiles each
      # way of the map the build made, so it is that many `set_tile`s: a changed cell as any other.
      def write(background, col, row, word)
        word = number_of!(word, background.name)
        return write_picked_by(background, col, row, word) if word.is_a?(Value)

        # A number past the layout's would be read without its high bits, as another cell.
        tiles = word.is_a?(Integer) && word.between?(0, most_number) && tiles_of(word)
        tiles or raise ArgumentError, untold_cell_message(background, word)
        write_tiles(background, col, row, tiles)
      end

      private

      def write_tiles(background, col, row, tiles)
        tiles.each_with_index do |tile, at|
          along = at % side
          down = at / side
          background.set_tile(side == 1 ? col : (col * side) + along, side == 1 ? row : (row * side) + down, tile)
        end
      end

      # A NUMBER THE GAME WORKS OUT, as the original works its text out: a letter read from a
      # table, plus a base. Which picture a number stands for was settled when the game was built,
      # and the told numbers are mostly a run (a font's cells, one after another), so the number
      # is kept once and picks its tile from the run's list (Background#set_tile_picked): what a
      # console's own game does, where the number is the tile. A number not told stands for no
      # tile, and the cell is left alone.
      #
      # Told numbers far apart (two fonts, a letter turned another way) are several runs, and
      # tests that halve the runs find which one the number is in.
      #
      # A background whose walls follow its tiles keeps the tests that halve the told numbers,
      # each with a `set_tile` of its own, since the wall goes with the tile.
      def write_picked_by(background, col, row, word)
        kept = (word & format.read_bits).hidden_copy
        words = tiles_by_word.keys.sort
        return write_between(background, col, row, kept, words) if background.walls_follow_tiles?

        write_run_between(background, col, row, kept, runs_of(words))
      end

      # How far apart two told numbers can be and still be in one run. The numbers between them
      # that were not told each take an entry of the run's list that stands for no tile.
      MOST_GAP_IN_RUN = 16

      # +words+, sorted, as runs: each a list of numbers no further apart than MOST_GAP_IN_RUN.
      def runs_of(words) = words.slice_when { |before, after| after - before > MOST_GAP_IN_RUN }.to_a

      def write_run_between(background, col, row, kept, runs)
        return write_from_run(background, col, row, kept, runs.first) if runs.one?

        lower, upper = runs.each_slice(runs.length.ceildiv(2)).to_a
        which = PlainRuby::Steps::GameTest.new(kept < upper.first.first)
        which.open_yes_side
        write_run_between(background, col, row, kept, lower)
        which.close_side(nil)
        which.open_no_side
        write_run_between(background, col, row, kept, upper)
        which.close_side(nil)
      end

      # The cell's tiles, each picked from the list of what the numbers of +run+ put there.
      def write_from_run(background, col, row, kept, run)
        (side * side).times do |at|
          keys = (run.first..run.last).map { |word| tiles_by_word[word]&.fetch(at) }
          background.set_tile_picked(side == 1 ? col : (col * side) + (at % side), side == 1 ? row : (row * side) + (at / side),
                                     kept, keys, from: run.first)
        end
      end

      def write_between(background, col, row, kept, words)
        return write_if_equal(background, col, row, kept, words.first) if words.one?

        lower, upper = words.each_slice(words.length.ceildiv(2)).to_a
        which = PlainRuby::Steps::GameTest.new(kept < upper.first)
        which.open_yes_side
        write_between(background, col, row, kept, lower)
        which.close_side(nil)
        which.open_no_side
        write_between(background, col, row, kept, upper)
        which.close_side(nil)
      end

      def write_if_equal(background, col, row, kept, word)
        same = PlainRuby::Steps::GameTest.new(kept == word)
        same.open_yes_side
        write_tiles(background, col, row, tiles_by_word.fetch(word))
        same.close_side(nil)
      end

      def untold_cell_message(background, word)
        "background :#{background.name} was not told that set_cell can write #{cell_description(word)}. So the build made " \
          "no picture for it. To fix this, add the cell to the background's `set_cells:`."
      end

      # +word+ as a person reads it: a number of the original's in hexadecimal, or a map cell's parts.
      def cell_description(word)
        return "the cell #{word.inspect}" unless word.is_a?(Integer)
        return Kernel.format("the cell 0x%04X", word) unless map_cells? && word.between?(0, most_number)

        tile = format.cell_tile(word, 0, 0, 1)
        turns = tile.turns.map { |turn| ", #{turn.to_s.tr('_', ' ')}" }.join
        "the map cell with tile #{tile.tile}, bank #{tile.bank}#{turns}"
      end
    end
  end
end
