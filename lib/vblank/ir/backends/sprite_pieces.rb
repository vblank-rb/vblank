# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A SPRITE PICTURE CUT INTO SQUARES OF 8×8. The Color and the Super Nintendo both show a sprite
      # as pieces of eight pixels square, each one entry of the console's sprite table drawn from a
      # tile of its own, so a picture bigger than one square is shown as several placed side by side.
      # A square with nothing drawn in it is left out: it would take an entry of the table and show
      # nothing. What each pixel's number is — its place in a list of colours — is the console's;
      # where the squares fall, and which are left out, is the same on both.
      #
      # A console whose table entry can draw a RECTANGLE OF SQUARES, the Genesis's up to four across and
      # four down, covers the picture instead (#cover): few such pieces that take in every square with
      # something drawn in it. The squares are found the same way; only how they are grouped differs. A Genesis shows 80 entries at once and 20 on a row of the screen, so a
      # picture of 112×72 cut into 8×8 squares takes most of the table on its own, and the same picture
      # covered takes a dozen.
      module SpritePieces
        SIZE = 8

        # A piece of a picture's cover: where it sits in the picture (+across+ and +down+, in pixels), how
        # many squares across (+columns+) and down (+rows+) it is, and its squares' numbers, 64 to each,
        # down each column and then across (#cover).
        Block = Data.define(:across, :down, :columns, :rows, :squares)

        # The picture +width+ by +height+ pixels cut into squares, row by row from the top left, as
        # [across, down, the square's 64 numbers] with across and down in pixels. The block gives the
        # number at x, y inside the picture; past its right or bottom edge a square's pixels are 0. A
        # square that is 0 all over is left out. On a console told to draw its pieces taller
        # (+piece_height+ 16, the Color's 8×16), each is that tall, its numbers row after row.
        def self.cut(width, height, piece_height: SIZE, &)
          (0...height).step(piece_height).flat_map do |down|
            (0...width).step(SIZE).filter_map do |across|
              square = square_at(width, height, across, down, piece_height, &)
              [across, down, square] unless square.all?(&:zero?)
            end
          end
        end

        # THE PICTURE COVERED BY RECTANGLES OF SQUARES, each up to +most+ squares across and +most+ down,
        # as Blocks. Every square with something drawn in it is in one; a rectangle may take in blank
        # squares too, which cost the console a tile of memory each but no entry of its table. The block
        # gives the number at x, y, as #cut's does.
        #
        # The cover is a grid of blocks +most+ squares on a side, laid from the top left of the squares
        # with something drawn in them, and each block's piece is the smallest rectangle round the drawn
        # squares inside it; a block with none has no piece. So a picture drawn all over is whole pieces
        # of 32×32 with narrower ones down its right edge and shorter ones along its bottom, a row of the
        # screen crosses as few pieces as the picture is wide in 32s, and never more pieces than #cut
        # makes, since each piece takes in at least one of #cut's squares.
        #
        # NO TWO PIECES OVERLAP. A Genesis draws at most 320 pixels of sprites on a row of the screen,
        # blank ones included, and leaves the rest of the row's sprites out; a square drawn by two
        # pieces would spend its eight pixels twice.
        #
        # A rectangle's squares are listed down each column and then across, as a Genesis reads the tiles
        # of a piece.
        def self.cover(width, height, most:, &)
          columns = (width + SIZE - 1) / SIZE
          rows = (height + SIZE - 1) / SIZE
          squares = Array.new(rows) { |row| Array.new(columns) { |column| square_at(width, height, column * SIZE, row * SIZE, SIZE, &) } }
          drawn = (0...rows).to_a.product((0...columns).to_a).select { |row, column| squares[row][column].any?(&:nonzero?) }
          return [] if drawn.empty?

          top = drawn.map(&:first).min
          left = drawn.map(&:last).min
          drawn.group_by { |row, column| [(row - top) / most, (column - left) / most] }.map do |_, inside|
            row = inside.map(&:first).min
            column = inside.map(&:last).min
            wide = inside.map(&:last).max - column + 1
            tall = inside.map(&:first).max - row + 1
            Block.new(across: column * SIZE, down: row * SIZE, columns: wide, rows: tall,
                      squares: (0...wide).flat_map { |c| (0...tall).map { |r| squares[row + r][column + c] } })
          end
        end

        # The square of +SIZE+ across and +tall+ down whose top left is +across+, +down+ in the picture, its
        # numbers row after row: the block's, or 0 past the picture's edge.
        def self.square_at(width, height, across, down, tall)
          Array.new(SIZE * tall) do |i|
            x = across + (i % SIZE)
            y = down + (i / SIZE)
            x >= width || y >= height ? 0 : yield(x, y)
          end
        end
        private_class_method :square_at
      end
    end
  end
end
