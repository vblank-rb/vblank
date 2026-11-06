# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # HOW MANY SPRITES A LINE OF THE SCREEN SHOWS. A console that draws a sprite as pieces, each
      # an entry of its sprite table, reads the table again for every line of the screen as it draws
      # it, and has time to fetch only so many pieces for one line: the Game Boy Color, ten. It takes
      # the first that many entries that cover the line, in the table's order, and leaves the rest
      # out of THAT LINE ONLY. So a crowd of sprites side by side loses a slice of the ones listed
      # last, one line high and a piece wide, exactly where the crowd is, and the same sprite is
      # whole a line further down where fewer stand beside it. The table lists the sprite in front
      # first, so what goes is what is furthest back.
      #
      # Every backend draws a console's sprites this way (Console::Description
      # #sprite_pieces_drawn_a_line gives how many, nil where none counts them), the interpreter and the
      # runtimes that play a game as that console alike, so all of them leave out the same slices
      # the cartridge does. The pieces are the console's own (Backends::SpritePieces): blank ones are
      # not in the table, so they take nothing; a piece wholly off the left or right of the screen is
      # not written into it either, so it takes nothing; any other piece takes its place on each line
      # it covers whether or not that line has room left to draw it.
      module SpriteLines
        # Where each piece of a picture stands inside it, [across, down] in pixels, in the order the
        # table holds them, the first in front. A picture made of pieces (Assets::Image#pieces) is
        # those, put together as +piece_height+ asks; any other is cut into squares, blank ones left
        # out.
        def self.picture_places(image, piece_height:)
          if image.pieces
            stacked = SpritePieces.stacked(image.small_pieces.map { |dx, dy, own| [dx, dy, own.bytes] }, piece_height: piece_height)
            return stacked.reject { |_, _, piece| piece.all?(&:zero?) }.map { |dx, dy, _| [dx, dy] }
          end

          SpritePieces.cut(image.width, image.height, piece_height: piece_height) do |x, y|
            image.drawn_at?((y * image.width) + x) ? 1 : 0
          end.map { |dx, dy, _| [dx, dy] }
        end

        # The pieces of a picture the game paints from a list as it runs: every one of its grid,
        # left to right and then down, since what it will show is not known while it is built.
        def self.painted_places(width, height, piece_height:)
          (0...height).step(piece_height).flat_map { |down| (0...width).step(SpritePieces::SIZE).map { |across| [across, down] } }
        end

        # The pieces of a pose drawn from a set of sprite tiles ([across, down, tile] each).
        def self.tile_pose_places(pieces, piece_height:)
          placed = piece_height == SpritePieces::SIZE ? pieces : SpritePieces.paired_tiles(pieces)
          placed.map { |dx, dy, _| [dx, dy] }
        end

        # WHICH SLICES OF A FRAME'S SPRITES ARE LEFT OUT. +sprites+ are the frame's, front-most first
        # (the table's order), each [x, y, places] with places as #picture_places gives them. +most+
        # is how many pieces a line draws. What comes back is one entry for each sprite: nil for one
        # drawn whole, or for one that loses a slice, by each line of the screen it loses one on, the
        # pieces of it that cover that line as [across, left out?]. A pixel of it is then left out
        # where #left_out_at? answers true.
        def self.left_out(sprites, most:, piece_height:, screen_width:, screen_height:)
          taken = Hash.new(0)
          sprites.map do |x, y, places|
            lines = {}
            places.each do |across, down|
              left = x + across
              next unless left > -SpritePieces::SIZE && left < screen_width

              top = y + down
              ([top, 0].max...[top + piece_height, screen_height].min).each do |line|
                (lines[line] ||= []) << [across, taken[line] >= most]
                taken[line] += 1
              end
            end
            lines.select! { |_, pieces| pieces.any?(&:last) }
            lines.empty? ? nil : lines
          end
        end

        # Is column +col+ of a sprite's picture left out on screen line +line+? It is where a piece
        # left out of that line covers it and no piece drawn there does.
        def self.left_out_at?(lines, col, line)
          pieces = lines[line] or return false
          covering = pieces.select { |across, _| col >= across && col < across + SpritePieces::SIZE }
          !covering.empty? && covering.all?(&:last)
        end
      end
    end
  end
end
