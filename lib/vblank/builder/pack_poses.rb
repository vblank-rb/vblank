# frozen_string_literal: true

module VBlank
  class Builder
    # A POSE THAT IS ONE OF THE ORIGINAL'S OWN FRAMES, read from the data pack: its pieces from a
    # slot of bytes, kept as the port's Original::FrameLayout says, over tiles from a slot of tiles.
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.tiles   :title_sprites, count: 512, colors: 16
    #     slots.numbers :balloon,       count: 600, width: :byte, signed: false
    #   end
    #   colors :balloon, [...]
    #   image :balloon_0, tiles: pack[:title_sprites], frame: pack[:balloon].frame(0, layout: FRAME),
    #                     origin: [32, 48], colors: :balloon
    #
    # A frame's pieces sit from the object's place, some to its left and above it, and a picture's
    # pixels start at its top left. So the pose names +origin+, where the object's place is in the
    # picture, the same for every pose of one sprite, so the sprite does not jump as it changes pose.
    #
    # BUILT ALL-IN-ONE, the pieces are read here, and the pose is the picture of pieces a port
    # would have written by hand (`image ..., pieces:`), drawn from the tiles each piece names,
    # turned as it says: a piece of several tiles is the tiles its layout names, turned as one. So every
    # console draws it from those pieces, and every build draws it as any pose. With the pack left
    # out nothing here can be known, and the build says so.
    module PackPoses
      private

      def define_pack_pose(name, opts)
        refuse_pack_pose_left_out!(name)
        refuse_pack_pose_options!(name, opts)
        frame = opts[:frame]
        tile_places = pack_tile_places(opts[:tiles], "image :#{name}")
        refuse_slot_from_elsewhere!(frame.slot, "image :#{name}'s frame:")
        origin = refuse_bad_origin!(name, opts[:origin])
        pieces = frame_pieces(name, frame).flat_map do |piece|
          pack_piece_blocks(name, piece, frame.piece_layout, tile_places).map do |left, top, places|
            [origin[0] + piece.x + left, origin[1] + piece.y + top, places]
          end
        end
        refuse_piece_left_of_origin!(name, pieces)
        image name, pieces: pieces, colors: opts[:colors]
      end

      # The pieces of +frame+ (a DSL::PackFrame), read from its slot's bytes.
      def frame_pieces(name, frame)
        bytes = @data_pack_contents.bytes_of(frame.slot.layout.name).bytes
        layout = frame.piece_layout
        refuse_frame_past_slot!(name, frame) unless frame.at.is_a?(Integer) && frame.at.between?(0, bytes.length - 1)
        first = frame.at + layout.count_bytes_before_pieces
        refuse_frame_past_slot!(name, frame) if first > bytes.length
        count = layout.counted ? layout.count_of(bytes[frame.at, layout.count_bytes]) : frame.count
        refuse_frame_count!(name, frame, count)
        Array.new(count) do |at|
          record = bytes[first + (at * layout.piece_bytes), layout.piece_bytes]
          refuse_frame_past_slot!(name, frame) unless record&.length == layout.piece_bytes

          layout.piece_of(record)
        end
      end

      # +piece+ as the blocks a picture of pieces is made of, each [left, top, places] from the
      # piece's own top left. Its tiles are laid out as its layout orders them and the whole piece
      # is turned as it says, so a mirrored piece of four columns has its last column first. A
      # picture's pieces are 8x8 or 16x16, so the piece is then cut into blocks of 16x16 where two
      # tiles are left each way and of 8x8 along an odd edge: a piece of 4 by 4 tiles is four blocks.
      def pack_piece_blocks(name, piece, layout, tile_places)
        side = Original::Slot::TILE_SIDE
        rows = Array.new(piece.rows * side) do |y|
          Array.new(piece.columns * side) do |x|
            tile = pack_tile_at(tile_places, layout.piece_tile(piece, x / side, y / side), "image :#{name}")
            tile[((y % side) * side) + (x % side)]
          end
        end
        rows = turned_rows(rows, mirrored: piece.mirrored, upside_down: piece.upside_down)
        block_places(piece.columns, piece.rows).map do |column, row, tiles|
          [column * side, row * side, rows[row * side, tiles * side].flat_map { |line| line[column * side, tiles * side] }]
        end
      end

      # Where each block of a piece +columns+ by +rows+ tiles starts, in tiles, and how many tiles
      # a side it is (1 or 2): each [column, row, tiles].
      def block_places(columns, rows)
        (0...rows).step(2).flat_map do |row|
          (0...columns).step(2).flat_map do |column|
            next [[column, row, 2]] if column + 2 <= columns && row + 2 <= rows

            [row, row + 1].select { |r| r < rows }.product([column, column + 1].select { |c| c < columns })
                          .map { |r, c| [c, r, 1] }
          end
        end
      end

      def refuse_pack_pose_left_out!(name)
        return unless pack_left_out?

        raise ArgumentError, "image :#{name} reads a frame from the data pack, and this build reads its pack as the game " \
                             "starts. A pose from the pack is not made that way yet. To fix this, build the game all-in-one."
      end

      POSE_FROM_PACK_OPTIONS = %i[tiles frame origin colors].freeze

      def refuse_pack_pose_options!(name, opts)
        others = opts.keys - POSE_FROM_PACK_OPTIONS
        return if others.empty? && opts[:frame].is_a?(DSL::PackFrame) && opts[:colors]

        raise ArgumentError, "image :#{name} reads a frame from the data pack. It takes tiles:, frame:, origin: and " \
                             "colors:, like `image :#{name}, tiles: pack[:sprites], frame: pack[:frames].frame(0, " \
                             "layout: FRAME), origin: [16, 16], colors: :hero`."
      end

      def refuse_bad_origin!(name, origin)
        return origin if origin.is_a?(Array) && origin.length == 2 && origin.all? { |at| at.is_a?(Integer) && !at.negative? }

        raise ArgumentError, "image :#{name} needs origin: [x, y], where the object's place is in the picture, in " \
                             "whole pixels 0 or more. Got #{origin.inspect}."
      end

      def refuse_piece_left_of_origin!(name, pieces)
        return if pieces.all? { |dx, dy, _| dx >= 0 && dy >= 0 }

        raise ArgumentError, "image :#{name} has a piece left of or above the picture. To fix this, give a larger origin:."
      end

      def refuse_frame_count!(name, frame, count)
        return if count.is_a?(Integer) && count.positive?

        raise ArgumentError, "image :#{name} reads a frame of #{count.inspect} pieces. A frame needs 1 or more. When its " \
                             "layout is not counted, give count: to `frame`."
      end

      def refuse_frame_past_slot!(name, frame)
        raise ArgumentError, "image :#{name} reads a frame from byte #{frame.at} of slot :#{frame.slot.layout.name}, and " \
                             "the frame ends past the slot. To fix this, correct the frame's place or the slot's count."
      end
    end
  end
end
