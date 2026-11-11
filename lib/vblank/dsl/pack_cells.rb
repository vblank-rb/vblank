# frozen_string_literal: true

module VBlank
  module DSL
    # THE CELLS A BACKGROUND FROM THE DATA PACK MAY BE WRITTEN LATER, each as the original's own
    # cell number (`background ..., set_cells:`, then Background#set_cell).
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

      # WRITE THE CELL at +col+ and +row+ of +background+ as +word+. A cell is +side+ tiles each
      # way of the map the build made, so it is that many `set_tile`s: a changed cell as any other.
      def write(background, col, row, word)
        return write_picked_by(background, col, row, word) if word.is_a?(Value)

        tiles = tiles_of(word) or raise ArgumentError, untold_cell_message(background, word)
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
      # so the number is kept once and found among the told ones by tests that halve them, as
      # Background#set_tile finds a tile picked by a number. A number not told matches none, and
      # the cell is left alone.
      def write_picked_by(background, col, row, word)
        kept = (word & format.read_bits).hidden_copy
        write_between(background, col, row, kept, tiles_by_word.keys.sort)
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
        "background :#{background.name} was not told it may be written the cell #{Kernel.format('0x%04X', word)}, so no picture " \
          "was made for it. To fix this, add the cell to the background's `set_cells:`."
      end
    end
  end
end
