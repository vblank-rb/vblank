# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The sizes of object the console has, and the limits on a picture cut into them,
        # under the names this backend has always used (see Backends::SpriteCut, which
        # holds them because the interpreter reads the cut too).
        OBJ_SIZES = SpriteCut::OBJ_SIZES
        OBJ_MAX_SIDE = SpriteCut::OBJ_MAX_SIDE
        MAX_OBJECT_CANVAS = SpriteCut::MAX_OBJECT_CANVAS
        MAX_OBJECT_PIECES = SpriteCut::MAX_OBJECT_PIECES

        # How a sprite's pictures are cut into the rectangles the console draws, and packed
        # into tiles the way it reads them. Nothing here knows about memory or about where a
        # sprite ends up: it is the art and the twelve shapes the hardware has.
        #
        # The cut itself — which boxes, and which poses are another one mirrored — is
        # SpriteCut's, since the interpreter reads it too. What is here is what only a
        # cartridge needs: refusing a picture that cannot be cut, and packing the tiles.
        class PoseCutter
          include Console::Hardware

          Mirror = SpriteCut::Mirror # A pose that is another pose turned

          def initialize(bitmaps)
            @bitmaps = bitmaps
          end

          # Everything about a sprite's poses that does not depend on memory: which poses are
          # another pose mirrored, and the boxes each pose is drawn from. Worked out before
          # any sprite is given a place in the console's table, because a picture too big for
          # one object is drawn as several and each of them takes a place of its own.
          #
          # A sprite that turns or resizes is neither trimmed nor mirrored, and that is
          # about being right rather than about being easy. The console spins an object
          # about the middle of its own box, so trimming the blank away would move the
          # pivot and the sprite would swing around a different point than the author drew
          # it to; and the two attribute bits that mirror an object are the ones that name
          # the rotation group once it is turning, so there are none left to mirror with.
          def cut(node, transformed:)
            # Poses of different sizes are drawn on the box they all fit in, each from its
            # top-left corner (see SpriteCut.canvas_of).
            width, height = SpriteCut.canvas_of(@bitmaps, node.poses)
            guard_canvas!(node, width, height, transformed: transformed)
            # Each pose is stored at its own size, trimmed to what it actually draws
            # (see SpriteCut#pieces_of) rather than at the canvas they were all drawn on.
            { width: width, height: height,
              **SpriteCut.new(@bitmaps).cut(node.poses, width: width, height: height, whole: transformed) }
          end

          # Pack a sprite's picture into tiles the way sprite hardware reads them: 8x8
          # tiles in reading order (left to right, top to bottom), each tile's 64 pixels
          # row by row, every pixel a number picking a color out of the table. A
          # see-through pixel becomes 0. Because we use 1D mapping, the tiles simply sit
          # one after another in memory.
          #
          # A narrow sprite packs two pixels into every byte — the left one in the low
          # half, the right one in the high half, which is the order the console reads
          # them back in — so its picture is half the size for the same pixels. (In this
          # console's own words: 4bpp, low nibble first. A 4bpp OBJ tile is 32 bytes and an
          # 8bpp one 64, but OBJ tile numbers count in 32s either way — which is why a wide
          # sprite has to start on an even one, see ScreenLayout#prepare_objects.)
          #
          # The same picture stored from the same box with the same colour numbers comes out
          # the same bytes, so a later build holding it reads them back (see IR::Remembered).
          def encode(bmp, placement, box = nil)
            IR::Remembered.fetch(:sprite_tiles, bmp, box, placement.narrow?, placement.indices) do
              encode_without_remembering(bmp, placement, box)
            end
          end

          # The work of #encode, every pixel of the box read, with nothing kept for later.
          def encode_without_remembering(bmp, placement, box)
            width = bmp.width
            height = bmp.height
            indices = placement.indices
            bytes = (+"").b
            # The part of the picture this pose is stored from — its whole self unless it
            # was trimmed to what it draws (see SpriteCut#pieces_of).
            box_x, box_y, box_w, box_h = box || [0, 0, width, height]
            (box_h / TILE_PX).times do |tile_row|
              (box_w / TILE_PX).times do |tile_col|
                TILE_PX.times do |row|
                  pending = nil
                  TILE_PX.times do |col|
                    y = box_y + (tile_row * TILE_PX) + row
                    x = box_x + (tile_col * TILE_PX) + col
                    # A piece of a cut-up picture can hang past the canvas's edge (see
                    # SpriteCut#grid_cells); what is out there draws nothing.
                    index = if x >= width || y >= height
                              0
                            else
                              i = (y * width) + x
                              bmp.drawn_at?(i) ? slot_of(bmp, i, indices, placement) : 0
                            end
                    next bytes << index.chr unless placement.narrow?

                    if pending.nil?
                      pending = index
                    else
                      bytes << (pending | (index << 4)).chr
                      pending = nil
                    end
                  end
                end
              end
            end
            bytes
          end

          # Which number one pixel is stored as.
          #
          # A picture that got a bank of sixteen reads its colors out of the author's own
          # list, so a place in that list is the number to write — which is what keeps two
          # places holding the same color apart. A picture stored the big way reads the
          # whole shared table instead, where the same color is one entry however many
          # places the author's list gave it, so there is nothing to keep apart and the
          # color is looked up.
          def slot_of(bmp, index, indices, placement)
            place = placement.narrow? && bmp.place_at(index)
            place || indices.fetch(bmp.color_at(index))
          end

          # One piece of a pose of several banks as its sprite entry's tiles (SpriteCut#piece_places_of):
          # the piece's own places, never the picture's, so where it is see-through over a piece of
          # another bank behind it the entry holds nothing and the entry behind shows through. Each
          # place is counted within its own bank, +bank_places+ to a bank, half a byte a pixel, the
          # left pixel in the low half, in 8x8 tiles in reading order.
          def encode_piece(own, bank_places)
            side = Assets::Image.side(own)
            places = own.bytes.map { |place| place.zero? ? 0 : place % bank_places }
            tiles = side / TILE_PX
            (0...tiles).flat_map do |tile_row|
              (0...tiles).flat_map do |tile_col|
                (0...TILE_PX).flat_map do |row|
                  line = places[(((tile_row * TILE_PX) + row) * side) + (tile_col * TILE_PX), TILE_PX]
                  line.each_slice(2).map { |left, right| left | (right << 4) }
                end
              end
            end.pack("C*")
          end

          private

          # The picture the author drew has to be made of whole tiles, and small enough that
          # the pose table can hold where each of its pieces sits. Everything between those
          # two the framework cuts up for itself, so this is the whole of what it refuses.
          # The message names the picture rather than the sprite, since a sprite's own name
          # is the framework's and the author named the art.
          def guard_canvas!(node, width, height, transformed:)
            art = node.poses.first
            node.poses.each do |pose|
              bmp = @bitmaps.fetch(pose)
              next if (bmp.width % TILE_PX).zero? && (bmp.height % TILE_PX).zero?

              raise LoweringError,
                    "A sprite the console draws (in screen :tiled, or with over_picture: true) is built " \
                    "from #{TILE_PX}x#{TILE_PX} tiles. So its picture " \
                    "must be a multiple of #{TILE_PX} pixels each way. The picture :#{pose} is " \
                    "#{bmp.width}x#{bmp.height}. To fix this, resize it."
            end
            if width > MAX_OBJECT_CANVAS || height > MAX_OBJECT_CANVAS
              raise LoweringError,
                    "A sprite the console draws (in screen :tiled, or with over_picture: true) can be " \
                    "#{MAX_OBJECT_CANVAS} pixels each way at most. " \
                    "The picture :#{art} is #{width}x#{height}. To fix this, draw it smaller, or build " \
                    "this part of the picture from a background instead."
            end
            return if !transformed || OBJ_SIZES.key?([width, height])

            raise LoweringError,
                  "A sprite that turns or changes size must be one of these sizes: " \
                  "#{OBJ_SIZES.keys.map { |w, h| "#{w}x#{h}" }.join(', ')}. The picture :#{art} is " \
                  "#{width}x#{height}. A picture that size is drawn as several sprites at once. The console " \
                  "turns each sprite about its own middle, so the picture will come apart. To fix this, draw " \
                  "it at one of the sizes above, or do not turn or resize it."
          end
        end
      end
    end
  end
end
