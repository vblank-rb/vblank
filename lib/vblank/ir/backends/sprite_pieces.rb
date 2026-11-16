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
        BIG = 16 # A side of the Super Nintendo's bigger pieces
        BIG_LEAST_SQUARES = 2 # The fewest drawn 8×8 squares that make one of them: one saves no entry
        RECTANGLE_SQUARES = 4 # The most squares across, and down, of the Genesis's pieces

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

        # A PICTURE THE GAME MADE OF 8×8 PIECES, as a console drawing pieces +piece_height+ tall
        # draws them: [across, down, numbers] each, as they are where pieces are 8×8. Where they are
        # 8×16, a piece with the one the game put right under it (or over it) is one tall piece, in
        # the place of the earlier of the two in the order, and a piece with none has a see-through
        # half under it. A piece's numbers are an Array, its rows one after another; a tall piece's
        # are the upper half's and then the lower's.
        def self.stacked(pieces, piece_height: SIZE)
          return pieces if piece_height == SIZE

          left = pieces.dup
          blank = Array.new(SIZE * SIZE, 0)
          drawn = []
          until left.empty?
            dx, dy, piece = left.shift
            under = left.index { |x, y, _| x == dx && y == dy + SIZE }
            over = left.index { |x, y, _| x == dx && y == dy - SIZE } unless under
            drawn << if under then [dx, dy, piece + left.delete_at(under)[2]]
                     elsif over then [dx, dy - SIZE, left.delete_at(over)[2] + piece]
                     else [dx, dy, piece + blank]
                     end
          end
          drawn
        end

        # A POSE DRAWN FROM A SET OF SPRITE TILES ([across, down, tile] each), as a console drawing
        # pieces 8×16 draws it: a tile with the next tile of the set right under it (or the one before
        # over it) is one tall piece, [across, down, the upper tile]. A tile with no such partner is
        # handed to the block, whose answer stands in for it; with no block it stays a piece alone.
        def self.paired_tiles(pieces)
          left = pieces.dup
          paired = []
          until left.empty?
            dx, dy, tile = left.shift
            under = left.index { |x, y, t| x == dx && y == dy + SIZE && t == tile + 1 }
            over = left.index { |x, y, t| x == dx && y == dy - SIZE && t == tile - 1 } unless under
            top = under ? tile : tile - 1
            unless (under || over) && top.even?
              paired << (block_given? ? yield(dx, dy, tile) : [dx, dy, tile])
              next
            end

            paired << (under ? [dx, dy, tile] : [dx, dy - SIZE, tile - 1])
            left.delete_at(under || over)
          end
          paired
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

        # SQUARES OF 16×16 FROM SQUARES OF 8×8, for a console whose table entry can draw four of them
        # as one (the Super Nintendo's): each square of the picture's grid of 16 that has +least+ or
        # more of its four quarters among +drawn+ ([across, down] of the 8×8 squares with something
        # drawn), as [across, down], the top row first. A square with one quarter drawn saves no entry.
        def self.big_squares(drawn, width, height, least:)
          drawn = drawn.to_set
          downs = (0..(height - BIG)).step(BIG).to_a
          acrosses = (0..(width - BIG)).step(BIG).to_a
          downs.product(acrosses).filter_map do |down, across|
            [across, down] if big_square_quarters(across, down).count { |quarter| drawn.include?(quarter) } >= least
          end
        end

        # The four 8×8 squares of the square of 16×16 at +across+, +down+: left top, right top, left
        # bottom, right bottom.
        def self.big_square_quarters(across, down)
          [[across, down], [across + SIZE, down], [across, down + SIZE], [across + SIZE, down + SIZE]]
        end

        # The 8×8 squares of a piece a game made a picture of (Assets::Image#pieces), [across, down,
        # places] each: the piece itself, or a piece of 16×16 as its four quarters.
        def self.piece_squares(piece)
          dx, dy, own = piece
          return [[dx, dy, own]] if Assets::Image.side(own) == Assets::PIECE_SIZE

          Assets::Image.quarters(own).map { |across, down, quarter| [dx + across, dy + down, quarter] }
        end

        # +squares+ ([across, down, places] each) as one rectangle, [left, top, columns, rows, its
        # squares' places down each column and then across], or nil where they are not every square of
        # a rectangle of up to +most+ squares each way.
        def self.rectangle(squares, most:)
          left = squares.map { |x, _, _| x }.min
          top = squares.map { |_, y, _| y }.min
          return nil unless squares.all? { |x, y, _| ((x - left) % SIZE).zero? && ((y - top) % SIZE).zero? }

          placed = squares.to_h { |x, y, own| [[(x - left) / SIZE, (y - top) / SIZE], own] }
          columns = placed.keys.map(&:first).max + 1
          rows = placed.keys.map(&:last).max + 1
          return nil if columns > most || rows > most || placed.length != squares.length || columns * rows != squares.length

          [left, top, columns, rows, (0...columns).flat_map { |column| (0...rows).map { |row| placed.fetch([column, row]) } }]
        end

        # A PICTURE MADE OF A CONSOLE'S OWN PIECES IN GROUPS (Assets::Image#piece_groups), as rectangles
        # of up to +most+ squares each way: each group one rectangle where its pieces make a whole one,
        # and a rectangle for each piece of it where they do not, in the picture's order, the first in
        # front. A rectangle that draws nothing is left out.
        def self.group_rectangles(image, most:)
          at = 0
          rectangles = image.piece_groups.flat_map do |count|
            group = image.pieces[at, count]
            at += count
            whole = rectangle(group.flat_map { |piece| piece_squares(piece) }, most: most)
            whole ? [whole] : group.map { |piece| rectangle(piece_squares(piece), most: most) }
          end
          rectangles.reject { |_, _, _, _, squares| squares.all? { |own| own.bytes.all?(&:zero?) } }
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
