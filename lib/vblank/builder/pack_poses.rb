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
    # THE LAYOUT IS READ BY THE PACK'S UNPACKING AND BY NOTHING ELSE. The unpacking writes each
    # frame a game names again as a record of VBlank's own (Original::FrameRecord), one layout
    # whatever the original's, after the pack's last slot; the frames named are counted here
    # (#pack_frame_number). Whatever draws a pose reads that record: this build where it holds the
    # pack, and the interpreter and each runtime where it does not.
    #
    # A frame's pieces sit from the object's place, some to its left and above it, and a picture's
    # pixels start at its top left. So the pose names +origin+, where the object's place is in the
    # picture, the same for every pose of one sprite, so the sprite does not jump as it changes pose.
    #
    # BUILT ALL-IN-ONE, the pieces are read here, and the pose is the picture of pieces a port
    # would have written by hand (`image ..., pieces:`), drawn from the tiles each piece names,
    # turned as it says: a piece of several tiles is the tiles its record names, turned as one. So every
    # console draws it from those pieces, and every build draws it as any pose. A picture's pieces
    # are 8x8 or 16x16, so a bigger piece of the frame is cut, and the picture keeps which of its
    # pieces were one (IR::Assets::Image#piece_groups) for a console that draws a piece that big.
    #
    # COLOURS FROM THE FRAME. A console's sprite entry names the bank of colours a piece is drawn
    # from, and which bank a frame uses is in the player's copy. Where the frame's layout says
    # where that is (`bank_bit:`) and `colors:` is a whole slot of colours, the pose is drawn from
    # the list of its pieces' bank, `:<slot>_<bank>` (#pose_bank_list!):
    #
    #   image :part_12, tiles: pack[:video], frame: pack[:frames].frame(at, layout: FRAME),
    #                   origin: [32, 48], colors: pack[:title_colors]
    #
    # A frame whose pieces name several banks is one pose told them, `banks: [4, 2]`, each piece
    # drawn from its own bank's list (#refuse_bad_pose_banks!).
    #
    # THE PICTURE'S SIZE is as far as its pieces reach, or `size: [width, height]` where the game
    # gives one: see-through past the pieces, so every pose of a sprite can be one size.
    #
    # WITH THE PACK LEFT OUT nothing of the frame is known here: not how many pieces it has, nor
    # where one sits, nor one pixel. So the game gives `size:`, and the pose is declared as a
    # picture of that size and by where its frame's record and its tiles are in the file the program
    # is handed as it starts (IR::StartFile::Pose). Each backend that plays such a program paints
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
        from_banks = pose_colors_from_banks?(frame, opts[:colors])
        refuse_bank_without_bank_colors!(name, opts.key?(:banks) ? "banks:" : "bank:") if (opts.key?(:bank) || opts.key?(:banks)) && !from_banks
        banks = (refuse_bad_pose_banks!(name, opts) if opts.key?(:banks))
        # ONE BANK NAMED is a pose of that bank's list, as `bank:` makes one, so it is drawn and
        # followed as any pose of one list, on every console; only a piece of another bank in the
        # pack the build holds is refused, where `bank:` leaves it out.
        told_one_bank = banks&.one?
        if told_one_bank
          opts = opts.except(:banks).merge(bank: banks.first)
          banks = nil
        end
        return define_pack_pose_read_at_start(name, opts, origin, size, from_banks: from_banks, banks: banks) if pack_left_out?

        tile_places = pack_tile_places(opts[:tiles], "image :#{name}")
        read = frame_pieces(name, frame)
        refuse_piece_outside_banks!(name, opts[:frame], read, [opts[:bank]]) if told_one_bank
        colors = opts[:colors]
        table = nil
        if banks
          bank_lists = declare_pack_color_banks(opts[:colors], opts[:tiles].layout.format.colors, "image :#{name}'s colors:")
          table = banks_table(name, banks, bank_lists)
          refuse_piece_outside_banks!(name, opts[:frame], read, banks)
        elsif from_banks
          read = pieces_of_bank(name, read, opts[:bank]) if opts.key?(:bank)
          colors = pose_bank_list!(name, opts, read)
        end
        bank_places = opts[:tiles].layout.format.colors
        blocks = read.map do |piece|
          shift = banks ? banks.index(piece.bank) * bank_places : 0
          pack_piece_blocks(name, piece, tile_places).map do |left, top, places|
            [origin[0] + piece.x + left, origin[1] + piece.y + top, places.map { |place| place.zero? ? 0 : place + shift }]
          end
        end
        pieces = blocks.flatten(1)
        refuse_piece_left_of_origin!(name, pieces)
        define_pose_of_frame_pieces(name, pieces, blocks.map(&:length), colors, size, table: table, bank_places: bank_places)
      end

      # The pose as a picture of +pieces+, as `image name, pieces:, colors:` makes one, which also
      # keeps how many of them each piece of the frame was cut into (+groups+). A console whose
      # sprite table draws a piece as big as the frame's then draws the frame's own pieces. A pose
      # of several banks is given its +table+ (#banks_table), +bank_places+ to a bank, and names no list.
      def define_pose_of_frame_pieces(name, pieces, groups, colors, size, table: nil, bank_places: nil)
        if table
          return define_pieced_image(name, pieces: pieces, colors: table, size: size, piece_groups: groups,
                                           table: table.map { |value| value || 0 }, bank_places: bank_places)
        end

        colors_name = colors if colors.is_a?(Symbol)
        list = colors_name ? declared_colors_for_image!(name, colors_name) : opts_with_pack_slots_read(name, colors: colors)[:colors]
        define_pieced_image(name, pieces: pieces, colors: list, colors_name: colors_name, size: size, piece_groups: groups)
      end

      # Whether the pose takes its colours from the bank its frame's pieces name: its layout says
      # where a piece's bank is, and `colors:` is a whole slot of colours and not one list of them.
      def pose_colors_from_banks?(frame, colors)
        frame.piece_layout.names_bank? && colors.is_a?(DSL::PackSlot) && colors.shape == :colors && !colors.bank?
      end

      # THE LIST A POSE IS DRAWN FROM WHERE ITS FRAME NAMES ITS BANK: the name of the list of the
      # one bank +pieces+ (FramePieces) are in. Each bank of the slot is the list `:<slot>_<bank>`,
      # the same lists a background from the slot is drawn from (PackBackgrounds), sized as the
      # tiles' own colours are counted. So the pose is a picture of one named list, as one a game
      # wrote with `colors: :title_colors_2` would be, and every console draws it as any picture.
      #
      # A picture named for one list is drawn from that list, so a frame with pieces in two banks
      # is not such a picture: the game is told, and names the banks with `banks:`
      # (#refuse_bad_pose_banks!), or makes a pose of each bank's pieces with `bank:`.
      def pose_bank_list!(name, opts, pieces)
        subject = "image :#{name}'s colors:"
        bank_lists = declare_pack_color_banks(opts[:colors], opts[:tiles].layout.format.colors, subject)
        banks = pieces.map(&:bank).uniq.sort
        refuse_frame_of_several_banks!(name, opts[:frame], banks) if banks.length > 1
        bank_lists.fetch(banks.first) do
          raise ArgumentError, "image :#{name} has a piece drawn from bank #{banks.first} of colors, and its colors: slot " \
                               "holds #{bank_lists.length} banks. To fix this, give it a slot that holds every bank its " \
                               "frames use."
        end
      end

      # The pieces of +pieces+ in bank +bank+, for a pose told `bank:`.
      def pieces_of_bank(name, pieces, bank)
        kept = pieces.select { |piece| piece.bank == bank }
        return kept unless kept.empty?

        banks = pieces.map(&:bank).uniq.sort
        raise ArgumentError, "image :#{name} was given bank: #{bank.inspect}, and no piece of its frame is drawn from " \
                             "bank #{bank.inspect}. Its pieces are drawn from bank #{banks.join(' and ')}. To fix this, " \
                             "give a bank that the frame uses, or leave out bank:."
      end

      def refuse_frame_of_several_banks!(name, frame, banks)
        named = "banks #{banks[0..-2].join(', ')} and #{banks.last}"
        raise ArgumentError, "image :#{name} reads the frame at byte #{frame.at} of slot :#{frame.slot.layout.name}, and " \
                             "its pieces are drawn from #{named} of colors. To fix this, give the pose the banks its " \
                             "frame uses: `banks: [#{banks.join(', ')}]`. Each piece is then drawn in the colors of its own bank."
      end

      def refuse_bank_without_bank_colors!(name, option)
        raise ArgumentError, "image :#{name} was given #{option}, and its pieces do not take their colors from their bank. " \
                             "#{option} is for a pose whose frame layout names a bank (bank_bit:) and whose colors: is a " \
                             "whole slot of colors, like `colors: pack[:palette]`. To fix this, leave out #{option}."
      end

      MOST_POSE_BANK = 30 # :nodoc: The runtimes hold a pose's banks as the bits of one number

      # A POSE OF SEVERAL BANKS (`banks: [4, 2]`). A console's sprite entry names the bank of
      # colours its piece is drawn from (GBATEK, "LCD OBJ - OAM Attributes": attribute 2, bits
      # 12-15), so a frame can be pieces of several banks that move as one thing. The game names the
      # banks its frame uses, since a build that reads its pack as the game starts cannot see them.
      # The pose's list is then each bank's list of the slot, `:<slot>_<bank>`, one after the other
      # in the order of their numbers, and a piece's places count into its own bank's part of it.
      # Hands back the banks, lowest first.
      def refuse_bad_pose_banks!(name, opts)
        banks = opts[:banks]
        if opts.key?(:bank)
          raise ArgumentError, "image :#{name} was given banks: and bank:. To fix this, give one of them: banks: for a pose " \
                               "of the pieces of several banks, or bank: for the pieces of one."
        end
        unless banks.is_a?(Array) && !banks.empty? && banks.all? { |bank| bank.is_a?(Integer) && bank.between?(0, MOST_POSE_BANK) }
          raise ArgumentError, "image :#{name} was given banks: #{banks.inspect}. banks: is a list of the banks of colors the " \
                               "pose's frame uses, each a whole number from 0 to #{MOST_POSE_BANK}, like `banks: [4, 2]`."
        end

        named = banks.uniq.sort
        refuse_too_many_pose_banks!(name, named, opts[:tiles].layout.format.colors)
        named
      end

      # A pose keeps a byte for each pixel's place in its list, so its banks' lists together hold
      # 256 colours at most: 16 banks of sixteen-colour tiles.
      MOST_POSE_PLACES = 256  # :nodoc:

      def refuse_too_many_pose_banks!(name, banks, bank_colors)
        most = MOST_POSE_PLACES / bank_colors
        return if banks.length <= most

        raise ArgumentError, "image :#{name} was given #{banks.length} banks. Its tiles have #{bank_colors} colors, so a " \
                             "pose can name #{most} banks at most: the colors of all its banks must be #{MOST_POSE_PLACES} or " \
                             "fewer. To fix this, give banks: only the banks the frame uses."
      end

      # The colours of a pose of the banks +banks+: the list of each bank (+bank_lists+, the slot's
      # lists by bank), one after the other, see-through first in each, as #define_placed_image
      # takes a table.
      def banks_table(name, banks, bank_lists)
        past = banks.reject { |bank| bank < bank_lists.length }
        unless past.empty?
          raise ArgumentError, "image :#{name} was given banks: #{banks.inspect}, and its colors: slot holds banks 0 to " \
                               "#{bank_lists.length - 1}. To fix this, give banks from 0 to #{bank_lists.length - 1}."
        end

        banks.flat_map { |bank| color_table(name, declared_colors_for_image!(name, bank_lists.fetch(bank))) }
      end

      def refuse_piece_outside_banks!(name, frame, pieces, banks)
        others = pieces.map(&:bank).uniq.sort - banks
        return if others.empty?

        raise ArgumentError, "image :#{name} reads the frame at byte #{frame.at} of slot :#{frame.slot.layout.name}, and " \
                             "a piece is drawn from bank #{others.first} of colors. Its banks: #{banks.inspect} do not hold " \
                             "bank #{others.first}. To fix this, add every bank the frame uses to banks:."
      end

      # WITH THE PACK LEFT OUT A POSE OF ONE BANK'S PIECES (`bank:`) is drawn from that bank's list,
      # `:<slot>_<bank>`, known as the game is built, and the routine that paints it as the game
      # starts paints only the pieces whose record names that bank (IR::StartFile::Pose#bank).
      # Which pieces those are is the file's: where none is, the pose is see-through, where the
      # build that holds the pack refuses the bank (#pieces_of_bank). Hands back the list's name.
      def bank_list_read_at_start(name, bank, bank_lists)
        return bank_lists.fetch(bank) if bank.is_a?(Integer) && bank.between?(0, bank_lists.length - 1)

        raise ArgumentError, "image :#{name} was given bank: #{bank.inspect}, and its colors: slot holds banks 0 to " \
                             "#{bank_lists.length - 1}. To fix this, give a bank from 0 to #{bank_lists.length - 1}."
      end

      # WITH THE PACK LEFT OUT THE BUILD CANNOT NAME THE LIST OF A POSE DRAWN IN ITS FRAME'S BANK:
      # which bank that is is in the file. So the pose's list is named for the pose's frame (a
      # STAND-IN), and the names of the lists it can be (+bank_lists+, by bank) are kept under it.
      # `colors_name_of` hands back the stand-in, and a sprite told to draw with it, or to follow
      # it, follows whichever of those lists the file picks (#follow_lists_chosen_at_start).
      # Hands back the stand-in.
      def pose_list_stand_in(name, slot, record, bank_lists)
        stand_in = :"#{pack_colors_name(slot)} bank of frame #{record}"
        (@lists_chosen_at_start ||= {})[stand_in] = bank_lists
        (@poses_in_frame_bank_colors ||= Set.new) << name
        stand_in
      end

      public

      # Whether +name+ is the stand-in for the list a pose's frame picks as the game starts
      # (#pose_list_stand_in). Asked by a sprite told to `draw_with` it, which then follows it.
      # Asked for a pose whose list its frame picks in a build that reads its pack as the game starts; documented with the pose.
      def list_chosen_at_start?(name) = !@lists_chosen_at_start.nil? && @lists_chosen_at_start.key?(name)  # :nodoc:

      # A SPRITE TOLD TO FOLLOW ITS POSES' LISTS WHERE A POSE'S LIST IS PICKED BY ITS FRAME AS THE
      # GAME STARTS (Images#follow_pose_lists, with the pack left out). Each name of +lists+ is a
      # stand-in, which the sprite follows as every list it can be, or a list a pose is drawn from;
      # each is followed and never drawn with another list. The object +node+ then names every list
      # it follows (IR::Nodes::Object#follows_each), and a pose shows what the list its frame picks
      # holds now. This is what the build that holds the pack makes of the same game: a sprite of
      # one list drawn with that list, or one of several that follows each.
      #
      # A frame whose pieces name two banks is drawn, and followed, in its front piece's: the
      # file is the player's, so nothing in it stops the game (#frame_bank_colors_read_at_start).
      # Called for a pose whose list its frame picks in a build that reads its pack as the game starts; documented with the pose.
      def follow_lists_chosen_at_start(node, lists, poses:, subject:)  # :nodoc:
        drawn = poses.map { |pose| list_drawn_from(pose).first }.uniq
        followed = lists.flat_map do |own, with|
          chosen = @lists_chosen_at_start[own]
          unless (chosen || drawn.include?(own) || @lists_chosen_at_start.values.any? { |names| names.include?(own) }) && with == own
            raise ArgumentError, "#{subject} was told to draw_with #{own.inspect} => #{with.inspect}, and this build reads " \
                                 "its pack as the game starts. Such a sprite can follow each list its pictures are drawn " \
                                 "from, like `#{own.inspect} => #{own.inspect}`. To fix this, follow the list and change its " \
                                 "colors with `recolor`. Or build the game all-in-one."
          end
          chosen || [own]
        end
        node.follows_each = ((node.follows_each || []) + followed).uniq
        (@pose_list_followers ||= []) << node
        nil
      end

      private

      # THE SAME POSE WITH THE PACK LEFT OUT (see the top of this file). The picture holds zeros of
      # the size the game gave, and its places are all 1, so the build treats it as a solid box.
      # Its colours are the game's own list, or a slot or bank of colours read from the file with
      # the frame, named for the slot as a picture's are (DataPacks#pack_colors_name), or, where
      # the pose takes them from the bank its frame names (+from_banks+), a marker for each colour
      # of that bank (#frame_bank_colors_read_at_start).
      #
      # A POSE OF SEVERAL BANKS (+banks+) holds a marker for each colour of each bank's list, as
      # built all-in-one, and the routine that paints it paints the pieces of those banks, each
      # place counted into its own bank's part of the list (IR::StartFile::Pose#banks). A piece of
      # another bank, which the build that holds the pack refuses, is not painted.
      def define_pack_pose_read_at_start(name, opts, origin, size, from_banks: false, banks: nil)
        refuse_pose_without_size!(name) unless size
        tiles = opts[:tiles]
        colors = opts[:colors]
        record = pack_frame_number(frame_source(name, opts[:frame]), name)
        entry_at = @pack_frames_at + (record * Original::FrameRecord::ENTRY_BYTES)
        colors_from_file = colors.is_a?(DSL::PackSlot) && !from_banks
        if colors.is_a?(DSL::PackSlot)
          refuse_slot_from_elsewhere!(colors, "image :#{name}'s colors:")
          refuse_slot_read_wrongly!(colors, :colors, "image :#{name}'s colors:")
          refuse_too_many_pack_colors!(name, colors) unless from_banks
        end
        bank_lists = (declare_bank_lists_read_at_start(colors, tiles.layout.format.colors, "image :#{name}'s colors:") if from_banks)
        one_bank = (bank_list_read_at_start(name, opts[:bank], bank_lists) if opts.key?(:bank))
        colors_name = if banks then nil
                      elsif one_bank then one_bank
                      elsif from_banks then pose_list_stand_in(name, colors, record, bank_lists)
                      else colors_from_file ? pack_colors_name(colors) : (colors if colors.is_a?(Symbol))
                      end
        table = if banks
                  banks_table(name, banks, bank_lists).map { |value| value || 0 }
                elsif one_bank
                  color_table(name, declared_colors_for_image!(name, one_bank)).map { |value| value || 0 }
                elsif from_banks
                  frame_bank_colors_read_at_start(name, opts, IR::StartFile::FrameBank.new(entry_at: entry_at, records_at: @pack_frames_at))
                elsif colors_from_file
                  Array.new(colors.count, 0)
                else
                  color_table(name, colors_name ? declared_colors_for_image!(name, colors_name) : colors).map { |value| value || 0 }
                end
        width, height = size
        first_tile = tiles.tile_index || 0
        node = Build.bitmap(name, width: width, height: height, pixels: Array.new(width * height, 0).pack("v*"), transparent: nil,
                                  colors: table, places: Array.new(width * height, 1).pack("C*"), colors_name: colors_name,
                                  bank_places: (tiles.layout.format.colors if banks))
        node.from_file = IR::StartFile::Pose.new(
          entry_at: entry_at, records_at: @pack_frames_at,
          origin_x: origin[0], origin_y: origin[1],
          tiles_at: @pack_slot_starts.fetch(tiles.layout.name) + (first_tile * tiles.layout.item_bytes),
          tile_count: tiles.layout.count - first_tile, tile_format: tiles.layout.format,
          colors_at: (colors_in_pack(colors) if colors_from_file), colors_count: table.length,
          color_format: (colors.layout.format if colors_from_file),
          bank: (opts[:bank] if one_bank), bank_lists: (bank_lists if from_banks && !one_bank && !banks), banks: banks
        )
        record_picture(node)
        (@pictures_from_start_file ||= {})[name] = node.from_file
        record_visible_bounds(name: name, width: width, height: height, cells: [], transparent: nil)
      end

      # THE COLOURS OF A POSE DRAWN IN THE BANK ITS FRAME NAMES, WITH THE PACK LEFT OUT. Which bank
      # that is is a number in the file: the bank the frame's front piece keeps in its record
      # (+choice+, an IR::StartFile::FrameBank). So the pose's list holds, for each place, a marker
      # of the colour at that place of whichever bank the file names (IR::StartFile::ChosenColor),
      # and the pose is filled as any pose that holds its colours is. The first place is
      # see-through, as in any picture's list.
      #
      # Each bank of the slot is declared as the list `:<slot>_<bank>` too, as built all-in-one
      # (#pose_bank_list!), so a game that recolours or walks one by that name builds.
      #
      # A FRAME OF TWO BANKS. The file is the player's, so nothing in it stops the game: a frame
      # whose pieces name two banks, which the build that holds the pack refuses, is drawn whole
      # in its front piece's bank, and a sprite following its list follows that bank's.
      def frame_bank_colors_read_at_start(name, opts, choice)
        slot = opts[:colors]
        size = opts[:tiles].layout.format.colors
        chosen = IR::StartFile::ChosenColor.new(choice: choice, at: colors_in_pack(slot), list_colors: size, lists: slot.count / size,
                                                place: 0, format: slot.layout.format)
        [0, *(1...size).map { |place| start_file_color_marker(chosen.with(place: place)) }]
      end

      # Each bank of +slot+ (a whole slot of colours), +size+ colours to a bank, as the list
      # `:<slot>_<bank>` of a marker for each colour, which is what a background from the slot
      # declares in such a build (PackBackgrounds#declare_bank_stand_in). Hands back the names.
      def declare_bank_lists_read_at_start(slot, size, subject)
        first = colors_in_pack(slot)
        Array.new(slot.count / size) do |bank|
          list = :"#{slot.layout.name}_#{bank}"
          held = Array.new(size) do |place|
            at = first + (((bank * size) + place) * slot.layout.item_bytes)
            start_file_color_marker(IR::StartFile::Color.new(at: at, format: slot.layout.format))
          end
          refuse_pack_color_list_taken!(subject, list) if @color_lists.key?(list) && @color_lists[list] != held
          @color_lists[list] = held
          (@color_lists_read_at_start ||= {})[list] = bank
          list
        end
      end

      # THE FRAME +frame+ (a DSL::PackFrame) AS THE PACK'S UNPACKING IS TOLD OF IT (an
      # Original::FrameRecord::Source): its slot, where it starts, and how it is kept. Where the
      # frame starts and, for one whose count the game gives, where it ends are the game's own
      # words, so they are held to the slot's size here, whichever way the game is built. A frame
      # that says its own count is in the player's copy: the build that holds the pack refuses one
      # that runs past its slot (#frame_pieces), and a build that does not draws the pieces that fit.
      #
      # A FRAME READ THROUGH A VIEW (DSL::PackSlot#as_numbers) is told of as the frame at the same
      # bytes of the slot the view reads: the unpacking finds a frame's bytes by a slot the pack
      # names. Its start is held to the view; a frame that says its own count may run on past the
      # view's end into the rest of that slot, as it would in the original.
      def frame_source(name, frame)
        layout = frame.piece_layout
        slot_bytes = frame.slot.layout.count
        refuse_frame_past_slot!(name, frame) unless frame.at.is_a?(Integer) && frame.at.between?(0, slot_bytes - 1)
        first = frame.at + layout.count_bytes_before_pieces
        refuse_frame_past_slot!(name, frame) if first > slot_bytes
        unless layout.counted
          refuse_frame_count!(name, frame, frame.count)
          refuse_frame_past_slot!(name, frame) if first + (frame.count * layout.piece_bytes) > slot_bytes
        end
        read = frame.slot.layout
        Original::FrameRecord::Source.new(slot: read.declared, at: read.start_in_declared + frame.at,
                                          count: (frame.count unless layout.counted), layout: layout, pose: frame.pose)
      end

      # THE FRAMES THE GAME HAS NAMED SO FAR, each once, in the order it named them: the frames
      # the pack keeps a record of after its last slot (Original::FrameRecord::Section). The number
      # of +source+ among them is its place in that section's directory. Both builds of one game
      # name the same frames in the same order, so the pack one makes is the file the other reads.
      # +picture+ is the image the frame is first read for, which an error gives.
      #
      # AN UNPACKING MADE ALREADY WRITES NO RECORD OF A FRAME NAMED AFTER IT (DSL::DataPack#unpacking
      # makes it from the frames named so far), so a new frame named then is refused rather than
      # left out of the pack in silence.
      def pack_frame_number(source, picture)
        @pack_frames ||= []
        found = @pack_frames.index(source)
        return found if found

        refuse_frame_after_unpacking!(picture, source) if @pack_unpacking_made
        (@pack_frame_pictures ||= {})[source] = picture
        (@pack_frames << source).length - 1
      end

      # The section those frames make.
      def pack_frame_section = Original::FrameRecord::Section.new(sources: (@pack_frames || []).dup.freeze)

      # The section for DSL::DataPack#unpacking, which makes its program from it: a frame named
      # after this is refused (#pack_frame_number).
      def pack_frame_section_for_unpacking!
        @pack_unpacking_made = true
        pack_frame_section
      end

      # ONCE THE WHOLE PROGRAM IS DECLARED: a program that reads its pack as it starts is told the
      # file's whole size, its frames' records after its slots. The size follows from the frames
      # the game named and never from what a frame holds (Original::FrameRecord::Section#size).
      # The build that holds the pack refuses frames that overlap past the room that size keeps.
      def finalize_pack_frames
        return unless @pack_frames

        return refuse_frames_without_room! unless pack_left_out?

        @program.start_file = @program.start_file.with(size: @pack_frames_at + pack_frame_section.size)
      end

      # Frames of one slot that overlap can hold more pieces between them than the pack keeps room
      # for (Original::FrameRecord::Section#index_of_first_without_room). The pack is made already,
      # so its bytes say which frame is the first without room.
      def refuse_frames_without_room!
        index = pack_frame_section.index_of_first_without_room(@data_pack_contents.slots)
        return unless index

        source = @pack_frames.fetch(index)
        raise ArgumentError, "image :#{@pack_frame_pictures.fetch(source)} " \
                             "#{Original::Unpacking::Fault.frames_without_room_message(source.at, source.slot.name)}"
      end

      def refuse_frame_after_unpacking!(name, source)
        raise ArgumentError, "image :#{name} reads the frame at byte #{source.at} of slot :#{source.slot.name}. The data " \
                             "pack's unpacking was made before this line, so it writes no record of this frame. To fix " \
                             "this, ask for `pack.unpacking` after the game names all its frames."
      end

      # The pieces of +frame+ (a DSL::PackFrame), read from its record: the bytes the pack's
      # unpacking writes for it, made here from what its slot holds. The record says how many
      # pieces the frame names and holds those that fit in its slot.
      def frame_pieces(name, frame)
        source = frame_source(name, frame)
        record = Original::FrameRecord.read(source.record(@data_pack_contents.bytes_of(source.slot.name)))
        refuse_frame_count!(name, frame, record.named)
        refuse_frame_past_slot!(name, frame) if record.pieces.length < record.named
        pack_frame_number(source, name)
        record.pieces
      end

      # +piece+ (an Original::FrameRecord::Piece) as the blocks a picture of pieces is made of,
      # each [left, top, places] from the piece's own top left. Its tiles are laid out as its
      # record steps through them and the whole piece
      # is turned as it says, so a mirrored piece of four columns has its last column first. A
      # picture's pieces are 8x8 or 16x16, so the piece is then cut into blocks of 16x16 where two
      # tiles are left each way and of 8x8 along an odd edge: a piece of 4 by 4 tiles is four blocks.
      def pack_piece_blocks(name, piece, tile_places)
        side = Original::Slot::TILE_SIDE
        rows = Array.new(piece.rows * side) do |y|
          Array.new(piece.columns * side) do |x|
            tile = pack_tile_at(tile_places, piece.tile_at(x / side, y / side), "image :#{name}")
            tile[((y % side) * side) + (x % side)]
          end
        end
        rows = turned_rows(rows, mirrored: piece.mirrored, upside_down: piece.upside_down)
        piece.blocks.map do |column, row, tiles|
          [column * side, row * side, rows[row * side, tiles * side].flat_map { |line| line[column * side, tiles * side] }]
        end
      end

      POSE_FROM_PACK_OPTIONS = %i[tiles frame origin colors size bank banks].freeze  # :nodoc:

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


      # THE ORIGIN NEED NOT BE INSIDE THE PICTURE. A frame whose pieces all sit below the object's
      # place (the Minish Cap's anvil stars sit a row under theirs) puts the place above the
      # picture: origin [32, -1]. What must be inside is each piece, origin plus its offset, and
      # that is held where the pieces are known: here when the build holds the pack
      # (#refuse_piece_left_of_origin!, and the size the pieces reach), and as the game starts
      # otherwise, where each backend paints only what lands inside the picture.
      def refuse_bad_origin!(name, origin)
        return origin if origin.is_a?(Array) && origin.length == 2 && origin.all?(Integer)

        raise ArgumentError, "image :#{name} was given origin: #{origin.inspect}. origin: must be [x, y] in whole pixels: " \
                             "the place of the object, counted from the top left of the picture. It can be outside the " \
                             "picture."
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
