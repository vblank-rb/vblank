# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # THE TILES IN VIDEO MEMORY, IN THEIR ORDER, and what names each one.
        #
        # A map cell and a sprite's piece both name a tile by its number, in a word that also holds two
        # bits that turn it: one draws it right to left, one bottom to top. So a tile is stored once
        # however many pictures draw it and whichever way round each shows it, and what is handed back
        # for a tile is that word's low bits: the number, and the turn that shows the tile asked for.
        #
        # A SPRITE'S PIECE OF SEVERAL TILES names only its first. The video chip takes the rest from
        # the tiles that follow it in video memory, down the piece's first column and then down the
        # next, and its turn bits turn the piece whole: mirrored, its last column is drawn first and
        # each tile right to left. So a piece needs its tiles in a row in video memory (a RUN), in
        # one of the four orders a turn can show, and a run already there in any of them is used as
        # it is, wherever it lies: inside a longer piece's run, or across tiles two other pictures
        # stored. A run not there is added after the last tile, less whatever tiles it starts with
        # that the store already ends with.
        #
        # WHAT TOOK THE ROOM. Each tile added is counted for the picture that asked for it first
        # (+taker+), so a build with too many can name the pictures that took the most.
        class TileStore
          # The bits of a cell's or a piece's word that turn its tile.
          MIRRORED = 0x0800
          UPSIDE_DOWN = 0x1000
          TURNS = [0, MIRRORED, UPSIDE_DOWN, MIRRORED | UPSIDE_DOWN].freeze

          BLANK = ("\0".b * TileBytes::BYTES).freeze

          attr_reader :tiles, :takers

          # A store holding tile 0 alone: nothing drawn, for an empty cell.
          def initialize
            @tiles = [BLANK]
            @words = { BLANK => 0 } # a tile's bytes => the number and turn that show it
            @places = { BLANK => [0] } # a tile's bytes => every number it is stored at
            @takers = Hash.new(0) # who asked first => how many tiles were added for it
          end

          # A store of its own that starts as this one is, for a scene's tiles after the shared ones.
          def initialize_copy(from)
            super
            @tiles = from.tiles.dup
            @words = @words.dup
            @places = @places.transform_values(&:dup)
            @takers = from.takers.dup
          end

          def length = @tiles.length

          # The number and turn that show the tile +bytes+, stored now if no turn of it was.
          def word_of(bytes, taker)
            @words.fetch(bytes) do
              add(bytes, taker)
              @words.fetch(bytes)
            end
          end

          # The first tile's number, and the turn, that show the piece +columns+ by +rows+ tiles whose
          # tiles are +tiles+ (each one's bytes, down each column and then across).
          def word_of_run(tiles, columns, rows, taker)
            return word_of(tiles.first, taker) if tiles.length == 1

            turned = TURNS.map { |turn| [turn, turned_run(tiles, rows, turn)] }
            turned.each do |turn, run|
              at = place_of_run(run)
              return at | turn if at
            end
            turn, run = turned.max_by { |_, candidate| tiles_shared_with_end(candidate) }
            shared = tiles_shared_with_end(run)
            first = @tiles.length - shared
            run.drop(shared).each { |bytes| add(bytes, taker) }
            first | turn
          end

          private

          # +bytes+ stored after the last tile. Each way round it can be shown is noted, unless a tile
          # stored before shows that already.
          def add(bytes, taker)
            number = @tiles.length
            @tiles << bytes
            (@places[bytes] ||= []) << number
            TURNS.each { |turn| @words[turned_tile(bytes, turn)] ||= number | turn }
            @takers[taker] += 1
          end

          def turned_tile(bytes, turn)
            bytes = TileBytes.mirrored(bytes) if turn.anybits?(MIRRORED)
            bytes = TileBytes.upside_down(bytes) if turn.anybits?(UPSIDE_DOWN)
            bytes
          end

          # The tiles video memory must hold in a row for a piece drawn with +turn+ to show +tiles+.
          def turned_run(tiles, rows, turn)
            columns = tiles.each_slice(rows).to_a
            columns = columns.reverse if turn.anybits?(MIRRORED)
            columns = columns.map(&:reverse) if turn.anybits?(UPSIDE_DOWN)
            columns.flatten.map { |bytes| turned_tile(bytes, turn) }
          end

          # Where +run+ lies in the store, the lowest such place, or nil.
          def place_of_run(run)
            last = @tiles.length - run.length
            @places.fetch(run.first, []).find do |at|
              at <= last && run.each_with_index.all? { |bytes, along| @tiles[at + along] == bytes }
            end
          end

          # How many tiles at the start of +run+ are the tiles the store ends with.
          def tiles_shared_with_end(run)
            (run.length - 1).downto(1).find { |count| count <= @tiles.length && @tiles.last(count) == run.first(count) } || 0
          end
        end
      end
    end
  end
end
