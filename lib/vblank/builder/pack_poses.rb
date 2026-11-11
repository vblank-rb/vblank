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
    # console draws it from those pieces, and every build draws it as any pose.
    #
    # THE PICTURE'S SIZE is as far as its pieces reach, or `size: [width, height]` where the game
    # gives one: see-through past the pieces, so every pose of a sprite can be one size.
    #
    # WITH THE PACK LEFT OUT nothing of the frame is known here: not how many pieces it has, nor
    # where one sits, nor one pixel. So the game gives `size:`, and the pose is declared as a
    # picture of that size and by where its frame and its tiles are in the file the program is
    # handed as it starts (IR::StartFile::Pose). Each backend that plays such a program paints
    # the pieces into the picture as it starts, as they are painted here. What the build must
    # still know is true of it: the size, and where the frame starts, which is checked against
    # the slot's size, the game's own word. The build sees a whole box of that size, as it does
    # of any picture read at start (DataPacks#define_picture_from_start_file).
    module PackPoses
      private

      def define_pack_pose(name, opts)
        refuse_pack_pose_options!(name, opts)
        frame = opts[:frame]
        refuse_tiles_not_from_slot!(opts[:tiles], "image :#{name}")
        refuse_slot_from_elsewhere!(opts[:tiles], "image :#{name}'s tiles:")
        refuse_slot_from_elsewhere!(frame.slot, "image :#{name}'s frame:")
        origin = refuse_bad_origin!(name, opts[:origin])
        size = refuse_bad_pieced_size!(name, opts[:size])
        return define_pack_pose_read_at_start(name, opts, origin, size) if pack_left_out?

        tile_places = pack_tile_places(opts[:tiles], "image :#{name}")
        pieces = frame_pieces(name, frame).flat_map do |piece|
          pack_piece_blocks(name, piece, frame.piece_layout, tile_places).map do |left, top, places|
            [origin[0] + piece.x + left, origin[1] + piece.y + top, places]
          end
        end
        refuse_piece_left_of_origin!(name, pieces)
        image name, pieces: pieces, colors: opts[:colors], **(size ? { size: size } : {})
      end

      # THE SAME POSE WITH THE PACK LEFT OUT (see the top of this file). The picture holds zeros of
      # the size the game gave, and its places are all 1, so the build treats it as a solid box.
      # Its colours are the game's own list, or a slot or bank of colours read from the file with
      # the frame, named for the slot as a picture's are (DataPacks#pack_colors_name).
      def define_pack_pose_read_at_start(name, opts, origin, size)
        refuse_pose_without_size!(name) unless size
        frame = opts[:frame]
        tiles = opts[:tiles]
        colors = opts[:colors]
        layout = frame.piece_layout
        refuse_frame_past_slot_at_start!(name, frame)
        colors_from_file = colors.is_a?(DSL::PackSlot)
        if colors_from_file
          refuse_slot_from_elsewhere!(colors, "image :#{name}'s colors:")
          refuse_slot_read_wrongly!(colors, :colors, "image :#{name}'s colors:")
          refuse_too_many_pack_colors!(name, colors)
        end
        colors_name = colors_from_file ? pack_colors_name(colors) : (colors if colors.is_a?(Symbol))
        table = if colors_from_file
                  Array.new(colors.count, 0)
                else
                  color_table(name, colors_name ? declared_colors_for_image!(name, colors_name) : colors).map { |value| value || 0 }
                end
        width, height = size
        first_tile = tiles.tile_index || 0
        slot_start = @pack_slot_starts.fetch(frame.slot.layout.name)
        node = Build.bitmap(name, width: width, height: height, pixels: Array.new(width * height, 0).pack("v*"), transparent: nil,
                                  colors: table, places: Array.new(width * height, 1).pack("C*"), colors_name: colors_name)
        node.from_file = IR::StartFile::Pose.new(
          frame_at: slot_start + frame.at, frame_end: slot_start + frame.slot.layout.count,
          count: (frame.count unless layout.counted), layout: layout, origin_x: origin[0], origin_y: origin[1],
          tiles_at: @pack_slot_starts.fetch(tiles.layout.name) + (first_tile * tiles.layout.item_bytes),
          tile_count: tiles.layout.count - first_tile, tile_format: tiles.layout.format,
          colors_at: (colors_in_pack(colors) if colors_from_file), colors_count: table.length,
          color_format: (colors.layout.format if colors_from_file)
        )
        record_picture(node)
        (@pictures_from_start_file ||= {})[name] = node.from_file
        record_visible_bounds(name: name, width: width, height: height, cells: [], transparent: nil)
      end

      # Where the frame starts and, for one whose count the game gives, where it ends are known
      # from the game's own words, so they are held to the slot's size here as an all-in-one
      # build holds them. A frame that says its own count is read while its pieces fit the slot.
      def refuse_frame_past_slot_at_start!(name, frame)
        layout = frame.piece_layout
        slot_bytes = frame.slot.layout.count
        refuse_frame_past_slot!(name, frame) unless frame.at.is_a?(Integer) && frame.at.between?(0, slot_bytes - 1)
        first = frame.at + layout.count_bytes_before_pieces
        refuse_frame_past_slot!(name, frame) if first > slot_bytes
        return if layout.counted

        refuse_frame_count!(name, frame, frame.count)
        refuse_frame_past_slot!(name, frame) if first + (frame.count * layout.piece_bytes) > slot_bytes
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

      POSE_FROM_PACK_OPTIONS = %i[tiles frame origin colors size].freeze

      def refuse_pack_pose_options!(name, opts)
        others = opts.keys - POSE_FROM_PACK_OPTIONS
        return if others.empty? && opts[:frame].is_a?(DSL::PackFrame) && opts[:colors]

        raise ArgumentError, "image :#{name} reads a frame from the data pack. It takes tiles:, frame:, origin:, " \
                             "colors: and size:, like `image :#{name}, tiles: pack[:sprites], frame: " \
                             "pack[:frames].frame(0, layout: FRAME), origin: [16, 16], colors: :hero, size: [32, 32]`."
      end

      def refuse_pose_without_size!(name)
        raise ArgumentError, "image :#{name} reads a frame from the data pack, and this build reads its pack as the game " \
                             "starts. The build does not know how far the frame's pieces reach, so the pose needs size: " \
                             "[width, height], the size of the picture, like `size: [32, 32]`. Give every pose of one " \
                             "sprite the same size, large enough for the largest."
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
