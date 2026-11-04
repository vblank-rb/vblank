# frozen_string_literal: true

require "zlib"

module VBlank
  module IR
    module Backends
      class SNES
        # THE TEXT LAYER'S TILES AND MAPS, worked out while the game is built (Runtime::TextLayer runs
        # them).
        #
        # A painted screen paints text into tiles of eight bits a pixel, which is slow on this
        # processor and a lot to send: four rows of 21 letters are about 6K of tiles, more than a
        # blank holds, and nearly a frame of painting. The console's own games never paint text.
        # They keep its letters as tiles in video RAM, put there once with the screen off, and a
        # line of text is a few cells of a background's map. So text the game writes at a place
        # known when it is built is drawn here, once, into tiles of the painted screen's second
        # background (four bits a pixel in Mode 3), and at run time it is only those cells.
        #
        # The text is drawn at its place, so the pixels in each tile are the ones the interpreter
        # paints there: the font's own pixels, offset by where the text starts inside its first
        # tile. Two texts with the same tile share it. A pixel's four bits pick a colour from one
        # of eight lists of sixteen, which are the first 128 places of the colour list the painted
        # screen paints from (SNES::PaintedArt): so a text whose colour's place is 1 to 127, and
        # not a multiple of 16 (the first colour of a list is see-through), is drawn with the
        # place's list and its place in it. Any other text is painted, as before.
        #
        # Video RAM has room for LAST_TILE - FIRST_TILE + 1 such tiles past the painted screen's
        # own (Runtime::TextLayer says where). Text past that is painted too.
        class TextLayerArt
          # The second background's tiles start at word $7000 of video RAM, 16 words a tile; the
          # ones past $78A0 (the painted screen's see-through tile) are free.
          FIRST_TILE = 138
          LAST_TILE = 255
          TILE_BYTES = 32
          # A cell showing nothing: tile 136, which is the painted screen's see-through tile and
          # every pixel nought, with both bytes the same so the copying engine can fill a map with
          # it by sending one byte over and over.
          EMPTY_CELL = 0x8888
          # A cell's priority bit: the text in front of the painted layer (whose cells have none).
          PRIORITY = 0x2000
          SCREEN_COLUMNS = 32
          SCREEN_ROWS = 28
          # A text's record in the table the runtime reads ("paint layer texts"): 32 bytes.
          RECORD_BYTES = 32

          # One text on the layer: the painted picture it stands for and its place, the rows and
          # columns of tiles it covers (every cell of them is its own, an empty one included), its
          # hash for PaintLog, and its cells, row by row.
          Text = Data.define(:number, :picture, :x, :y, :top, :bottom, :first, :last, :hash, :cells) do
            def columns_mask = ((1 << (last + 1)) - 1) & ~((1 << first) - 1)
          end

          attr_reader :texts

          def initialize
            @tiles = {} # a tile's 32 bytes -> its number
            @texts = []
            @numbered = {}
          end

          # Whether a place in the colour list can colour a pixel of the layer.
          def self.place_usable?(place) = place.between?(1, 127) && (place % 16).positive?

          # The pixels of +text+ in +font+ (a Graphics::Font) drawn at (+x+, +y+), as {[x, y] => true},
          # or nil when any falls off the screen.
          def self.pixels_at(text, font, x, y)
            drawn = {}
            font.each_pixel(text) { |px, py| drawn[[x + px, y + py]] = true }
            return nil if drawn.empty?
            return nil unless drawn.each_key.all? { |px, py| px.between?(0, (SCREEN_COLUMNS * 8) - 1) && py.between?(0, (SCREEN_ROWS * 8) - 1) }

            drawn
          end

          # The number of the text +key+ names, drawn from +drawn+ (screen pixels) in the colour at
          # +place+, standing for painted picture +picture+ at (+x+, +y+); made once. nil when its
          # new tiles do not fit.
          def text(key, picture:, x:, y:, drawn:, place:)
            return @numbered[key] if @numbered.key?(key)

            columns = drawn.each_key.map { |px, _| px / 8 }
            rows = drawn.each_key.map { |_, py| py / 8 }
            first, last = columns.minmax
            top, bottom = rows.minmax
            tiles = (top..bottom).flat_map { |row| (first..last).map { |column| tile_bytes(drawn, column, row, place % 16) } }
            fresh = tiles.compact.uniq.reject { |bytes| @tiles.key?(bytes) }
            return @numbered[key] = nil if @tiles.length + fresh.length > LAST_TILE - FIRST_TILE + 1

            fresh.each { |bytes| @tiles[bytes] = FIRST_TILE + @tiles.length }
            cells = tiles.map { |bytes| bytes ? @tiles.fetch(bytes) | ((place / 16) << 10) | PRIORITY : EMPTY_CELL }
            number = @texts.length
            hash = Zlib.crc32([number, picture, x, y].pack("l<4")) | 1
            @texts << Text.new(number: number, picture: picture, x: x, y: y, top: top, bottom: bottom, first: first,
                               last: last, hash: hash, cells: cells)
            @numbered[key] = number
          end

          # Every tile drawn, in the order of their numbers from FIRST_TILE, as video RAM takes them.
          def tile_bytes_in_order = @tiles.keys.join.b

          # The table the runtime reads: each text's record (Runtime::TextLayer::RECORD), then each
          # one's cells.
          def emit_tables(asm)
            asm.label("paint layer tile bytes")
            asm.data_words(@tiles.length * TILE_BYTES)
            asm.label("paint layer texts")
            @texts.each do |t|
              asm.data_words(t.picture, t.x, t.y, t.top, t.bottom, t.first, t.last, t.columns_mask & 0xFFFF,
                             t.columns_mask >> 16, t.hash & 0xFFFF, t.hash >> 16)
              asm.data_longs("paint layer cells #{t.number}")
              asm.data_bytes(0, 0, 0, 0, 0, 0, 0)
            end
            asm.data_words(0) if @texts.empty?
            @texts.each do |t|
              asm.label("paint layer cells #{t.number}")
              asm.data_words(*t.cells)
            end
            asm.label("paint layer tiles")
            asm.data_bytes(tile_bytes_in_order.bytes)
            asm.data_bytes(0) if @tiles.empty?
          end

          private

          # The 32 bytes of the layer's tile at (+column+, +row+) of the screen, each drawn pixel
          # +value+ (planes 0 and 1 of each row side by side, then planes 2 and 3), or nil when it
          # draws none.
          def tile_bytes(drawn, column, row, value)
            planes = Array.new(32, 0)
            any = false
            8.times do |py|
              8.times do |px|
                next unless drawn.key?([(column * 8) + px, (row * 8) + py])

                any = true
                bit = 0x80 >> px
                4.times do |plane|
                  next if value[plane].zero?

                  planes[((plane / 2) * 16) + (py * 2) + (plane % 2)] |= bit
                end
              end
            end
            any ? planes.pack("C*") : nil
          end
        end
      end
    end
  end
end
