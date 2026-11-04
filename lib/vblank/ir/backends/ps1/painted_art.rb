# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT A PAINTED SCREEN DRAWS WITH, made while the program is built: every picture the game
        # blits, and every text and digit it writes (each drawn once in its font and colour, as the
        # Genesis's PaintedArt does), cut into pieces and given a place in video RAM.
        #
        # A PICTURE IS READ BY THE GRAPHICS CHIP AS A TEXTURE, from a texture page: a window of video RAM
        # 256 texels square whose left edge is a multiple of 64 pixels and whose top is line 0 or 256, a
        # texel named by a byte across (u) and a byte down (v). So a piece is at most 256 down and never
        # crosses line 256, and it starts no more than 63 texels into its page, which leaves it 192 across
        # at the most (PIECE_WIDTH_PIXELS): a picture bigger than that is cut into several, each drawn as a
        # rectangle of its own at its place in the picture.
        #
        # The pieces are kept at 15 bits a texel, the colour itself: a texel the picture leaves
        # see-through is 0000h, which the chip does not draw, and every other has its top bit set
        # (Console::PS1Hardware::TEXEL_DRAWN), so black is drawn black.
        #
        # THEY GO TO THE RIGHT OF THE SCREEN'S PAGES (x 320 on, the whole height of video RAM), packed in
        # shelves of pieces: the tallest first, each shelf as tall as its first piece.
        class PaintedArt
          # A texture page is this many texels across and down, and starts at a multiple of
          # TEXTURE_PAGE_STEP_PIXELS across.
          TEXTURE_PAGE_TEXELS = 256
          TEXTURE_PAGE_STEP_PIXELS = 64
          PIECE_WIDTH_PIXELS = TEXTURE_PAGE_TEXELS - TEXTURE_PAGE_STEP_PIXELS
          PIECE_HEIGHT_LINES = TEXTURE_PAGE_TEXELS
          # The first column of video RAM right of the screen's pages.
          FIRST_FREE_COLUMN = Console::PS1Hardware::SCREEN_WIDTH

          # One piece of a picture: where it sits in the picture, its size, its texels row by row, and
          # once placed, where it is in video RAM.
          Piece = Struct.new(:dx, :dy, :width, :height, :texels, :x, :y) do
            # The draw mode naming the texture page this piece is read from.
            def draw_mode
              h = Console::PS1Hardware
              h::GP0_DRAW_MODE | (x / TEXTURE_PAGE_STEP_PIXELS) | ((y / TEXTURE_PAGE_TEXELS) << 4) | h::TEXTURE_15_BIT |
                h::DRAW_ON_SHOWN_PICTURE
            end

            # v << 8 | u: where in its page the piece starts.
            def texture_corner = ((y % TEXTURE_PAGE_TEXELS) << 8) | (x % TEXTURE_PAGE_STEP_PIXELS)

            # Its texels two to a word, the left one in the low half, as the chip's copy takes them.
            def words = texels.each_slice(2).map { |low, high| low | ((high || 0) << 16) }
          end

          Picture = Data.define(:label, :pieces)

          # A row of pieces in video RAM: its top line, how tall it is, and the first column still free.
          Shelf = Data.define(:top_line, :height, :free_column) do
            # Whether +piece+ fits at its free column: as tall as the shelf at most, and ending by the edge
            # of video RAM and of the texture page it starts in.
            def fits?(piece)
              page_right = ((free_column / TEXTURE_PAGE_STEP_PIXELS) * TEXTURE_PAGE_STEP_PIXELS) + TEXTURE_PAGE_TEXELS
              piece.height <= height && free_column + piece.width <= [Console::PS1Hardware::VRAM_WIDTH, page_right].min
            end
          end

          # Raised when the pictures need more video RAM than is left beside the screen's pages.
          class Full < LoweringError; end

          def initialize
            @pictures = {}
          end

          def pictures = @pictures.values

          # Registers the picture known by +key+, made from what the block gives the first time, and
          # returns its label: the block gives a colour for each [x, y] the picture draws, counted from
          # its corner (a place left of or above the corner too, for a letter that reaches there).
          def register_picture(key)
            @pictures.fetch(key) do
              drawn = yield
              label = "paint picture #{@pictures.length}"
              @pictures[key] = Picture.new(label: label, pieces: cut(drawn))
            end.label
          end

          # Every piece given its place in video RAM. Called once, after the last picture is registered.
          def allocate_video_ram!
            shelves = []
            pictures.flat_map(&:pieces).sort_by { |piece| -piece.height }.each { |piece| allocate_piece(piece, shelves) }
          end

          private

          # +drawn+ cut into pieces of at most PIECE_WIDTH_PIXELS × PIECE_HEIGHT_LINES, from the box round
          # what it draws; a piece that draws nothing is left out.
          def cut(drawn)
            return [] if drawn.empty?

            first_x, last_x = drawn.keys.map(&:first).minmax
            first_y, last_y = drawn.keys.map(&:last).minmax
            (first_y..last_y).step(PIECE_HEIGHT_LINES).flat_map do |top|
              (first_x..last_x).step(PIECE_WIDTH_PIXELS).filter_map do |left|
                across = [PIECE_WIDTH_PIXELS, last_x + 1 - left].min
                down = [PIECE_HEIGHT_LINES, last_y + 1 - top].min
                texels = Array.new(across * down) do |at|
                  color = drawn[[left + (at % across), top + (at / across)]]
                  color ? (color & 0x7FFF) | Console::PS1Hardware::TEXEL_DRAWN : 0
                end
                Piece.new(left, top, across, down, texels) if texels.any?(&:positive?)
              end
            end
          end

          # A piece goes on the first shelf it fits, or on a new shelf under the last in either half of
          # video RAM.
          def allocate_piece(piece, shelves)
            at = shelves.index { |shelf| shelf.fits?(piece) }
            unless at
              allocate_shelf(piece, shelves) or raise Full, full_message
              at = shelves.length - 1
            end
            shelf = shelves[at]
            piece.x = shelf.free_column
            piece.y = shelf.top_line
            shelves[at] = shelf.with(free_column: shelf.free_column + piece.width)
          end

          # A new shelf as tall as +piece+, added to +shelves+ under the last in the first half of video RAM
          # with room for it; nil when neither half has.
          def allocate_shelf(piece, shelves)
            [0, TEXTURE_PAGE_TEXELS].each do |half|
              in_half = shelves.select { |shelf| shelf.top_line >= half && shelf.top_line < half + TEXTURE_PAGE_TEXELS }
              top = in_half.map { |shelf| shelf.top_line + shelf.height }.max || half
              next if top + piece.height > half + TEXTURE_PAGE_TEXELS

              return Shelf.new(top_line: top, height: piece.height, free_column: FIRST_FREE_COLUMN).tap { |shelf| shelves << shelf }
            end
            nil
          end

          def full_message
            "This game draws more pictures and words than the PlayStation's video memory holds beside the " \
              "screen. To fix this, use fewer or smaller pictures, or fewer different words and colours of text."
          end
        end
      end
    end
  end
end
