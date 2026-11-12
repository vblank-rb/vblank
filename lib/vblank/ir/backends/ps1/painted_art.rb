# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT A PAINTED SCREEN DRAWS WITH, made while the program is built: every picture the game
        # blits, and every text and digit it writes (each drawn once in its font and colour, as the
        # Genesis's PaintedArt does), cut into pieces, each piece a texture in PS1::TextureMemory.
        #
        # A PIECE IS READ BY THE GRAPHICS CHIP FROM A TEXTURE PAGE, 256 texels square, whose left edge is
        # a multiple of 64 halfwords and whose top is line 0 or 256 (TextureMemory says how). So a piece
        # is at most 256 down and never crosses line 256, and at most PIECE_WIDTH_TEXELS across, which a
        # page holds from any of its first 64 halfwords at 15 bits: a picture bigger than that is cut into
        # several, each drawn as a rectangle of its own at its place in the picture.
        class PaintedArt
          PIECE_WIDTH_TEXELS = TextureMemory::PAGE_TEXELS - TextureMemory::PAGE_STEP_HALFWORDS
          PIECE_HEIGHT_LINES = TextureMemory::PAGE_TEXELS

          # One piece of a picture: where it sits in the picture, its size, and the texture it is read from.
          Piece = Data.define(:dx, :dy, :width, :height, :texture)

          Picture = Data.define(:label, :pieces)

          # +texture_memory+ is the PS1::TextureMemory the pieces' textures are added to.
          def initialize(texture_memory)
            @texture_memory = texture_memory
            @pictures = {}
          end

          def pictures = @pictures.values

          # Registers the picture known by +key+, made from what the block gives the first time, and
          # returns its label: the block gives a colour for each [x, y] the picture draws, counted from
          # its corner (a place left of or above the corner too, for a letter that reaches there).
          #
          # Read through a kept colour table (+table:+, TextureMemory#reserve_table), the block gives a place in
          # that table for each [x, y] instead of a colour.
          def register_picture(key, table: nil)
            @pictures.fetch(key) do
              drawn = yield
              label = "paint picture #{@pictures.length}"
              @pictures[key] = Picture.new(label: label, pieces: cut(drawn, table))
            end.label
          end

          private

          # +drawn+ cut into pieces of at most PIECE_WIDTH_TEXELS × PIECE_HEIGHT_LINES, from the box round
          # what it draws; a piece that draws nothing is left out.
          def cut(drawn, table)
            return [] if drawn.empty?

            first_x, last_x = drawn.keys.map(&:first).minmax
            first_y, last_y = drawn.keys.map(&:last).minmax
            (first_y..last_y).step(PIECE_HEIGHT_LINES).flat_map do |top|
              (first_x..last_x).step(PIECE_WIDTH_TEXELS).filter_map do |left|
                across = [PIECE_WIDTH_TEXELS, last_x + 1 - left].min
                down = [PIECE_HEIGHT_LINES, last_y + 1 - top].min
                colors = Array.new(across * down) { |at| drawn[[left + (at % across), top + (at / across)]] }
                next if colors.none?

                texture = if table
                            @texture_memory.add_texture(width: across, height: down, places: colors.map { |place| place || 0 }, table: table)
                          else
                            @texture_memory.add_texture(width: across, height: down, colors: colors)
                          end
                Piece.new(dx: left, dy: top, width: across, height: down, texture: texture)
              end
            end
          end
        end
      end
    end
  end
end
