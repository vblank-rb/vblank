# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # A sprite kept to one pose in video memory, lowered for a Genesis. Mixed into Lowering.
          #
          # Every picture a sprite can show normally sits in video memory for as long as its scene is up,
          # so showing another pose is pointing the sprite table at other tiles. A big character with many
          # frames can need more tiles than video memory holds beside the screen's other pictures (1471 in
          # all). The console's own games give such a character a room of tiles for one frame, and when he
          # changes frame they have the video chip copy that frame's tiles into the room from the cartridge
          # in the blank: Dr. Robotnik's Mean Bean Machine copies 88 tiles of Robotnik's for each frame of
          # his it shows. The Advance's build does the same (GBA::ScreenLayout#pick_set_for_one_frame).
          #
          # How it is decided, as the Advance decides it. A sprite whose pose the game can change (it faces
          # more than one, and its pose is not a number fixed as the game is built) can give tiles back.
          # The sprites facing the same poses, in the same order, are weighed together, as they read one
          # table of pictures: the tiles their poses take, less a room for each of them. The build that ran
          # out of tiles is tried again with the group that gives the most kept to one pose (#streamed_after),
          # and again with the next, until the tiles fit or none would give any back. A game whose tiles fit
          # is never built this way, so it is the bytes it was.
          #
          # What it costs. The pose each such sprite shows is noted as it is placed, one instruction. The
          # blank at the end of the pass (Runtime::Tiles#emit_upload) compares it with the pose last copied
          # in, and copies only on a change, before the sprite table that shows it, so the frame that first
          # shows a pose draws it from its own tiles. The rooms together are held to what the video chip
          # moves in a blank beside the sprite table and the colours (MOST_TILES), so every room changing on
          # one frame still lands before the screen is drawn.
          module PoseRooms
            # The most tiles all the rooms may hold together: what the video chip copies in one blank, less
            # the sprite table and the colour memory, which are copied in the same blank.
            MOST_TILES = (Console::GenesisHardware::BLANK_DMA_BYTES - (Runtime::Tiles::MOST_SPRITES * Runtime::Tiles::SPRITE_BYTES) -
                          (Art::PALETTES * Art::PLACES * 2)) / Art::TILE_BYTES

            # The routine the blank calls.
            POSES_SENT = "art poses sent"

            # A sprite's room: its first tile, the poses it faces, and where in work RAM the pose it shows
            # (+wanted+) and the pose last copied into the room (+sent+) are kept, each -1 for none yet.
            PoseRoom = Data.define(:first, :poses, :wanted, :sent)

            # Whether a sprite of the game is kept to one pose in video memory.
            public def streams_poses? = !@pose_rooms.to_h.empty?

            # The sprites to keep to one pose in the try after one that ran out of tiles with +streamed+ kept so
            # (Genesis#build): those, and the group of sprites facing the same poses that gives the most tiles
            # back. Nil where no group left would give any back, or its rooms would be more than MOST_TILES.
            # Asked of a try whose sprite pictures are cut already (Picture#make_sprite_art).
            public def streamed_after(streamed)
              return nil unless tiled?

              rooms = streamed.sum { |name| room_tiles(@objects.fetch(name).poses) }
              groups = @objects.values.reject { |obj| streamed.include?(obj.name) }.select { |obj| pose_changes?(obj) }.group_by(&:poses)
              freed = groups.filter_map do |poses, objects|
                next unless poses.all? { |name| @art.cut_of(name) }

                room = room_tiles(poses)
                next if rooms + (room * objects.length) > MOST_TILES

                gives = poses.uniq.flat_map { |name| @art.cut_tiles(name) }.uniq.length - (room * objects.length)
                [gives, objects] if gives.positive?
              end
              best = freed.max_by(&:first) or return nil
              (streamed + best.last.map(&:name)).freeze
            end

            private

            # Whether the game can change which pose +obj+ shows: it faces more than one, and its pose is
            # not a number the build knows.
            def pose_changes?(obj) = obj.poses.uniq.length > 1 && folded(obj.pose).nil?

            def streamed?(obj) = @streamed.include?(obj.name)

            # The tiles a room for +poses+ holds: the most any of them is cut into.
            def room_tiles(poses) = poses.uniq.map { |name| @art.cut_tiles(name).length }.max

            # What a sprite's picture drawn from its room is kept under in the art.
            def room_key(obj, name) = [:room, obj.name, name]

            # Each sprite kept to one pose given its room, among the tiles every screen shows, and its pictures
            # drawn from it (Art#room_picture); and the two numbers the blank compares (PoseRoom). Made before
            # any scene takes its copy of the tiles (Art#pose_room).
            def make_pose_rooms
              @pose_rooms = {}
              @objects.each_value do |obj|
                next unless streamed?(obj)

                obj.poses.uniq.each { |name| cut_sprite_picture(name) }
                first = @art.pose_room(room_tiles(obj.poses), "the room for one pose of the sprite :#{obj.name}")
                obj.poses.uniq.each { |name| @art.room_picture(room_key(obj, name), name, first) }
                wanted = @memory.reserve("the pose the sprite #{obj.name.inspect} shows", 4)
                sent = @memory.reserve("the pose copied into the room of the sprite #{obj.name.inspect}", 4)
                @starts << [wanted, -1] << [sent, -1]
                @pose_rooms[obj.name] = PoseRoom.new(first: first, poses: obj.poses, wanted: wanted, sent: sent)
              end
            end

            # D1, the pose a sprite placed shows (Picture#emit_sprite_placing), noted for the blank, where the
            # sprite has a room.
            def emit_pose_wanted(obj)
              room = @pose_rooms.to_h[obj.name] or return
              @asm.move(:l, @asm.d(1), at(room.wanted))
            end

            # The routine the blank calls (Runtime::Tiles#emit_upload), and what it reads: for each room whose
            # sprite shows a pose other than the one copied in, and one of its own, that pose's tiles copied
            # into the room by the video chip (Runtime::Tiles's rt_vram_run_copied). A sprite showing a pose
            # its table does not have draws nothing, and nothing is copied. For each list of poses, a table of
            # where each pose's tiles are and how many words they are, a long each; and each pose's tiles.
            def pose_rooms_sections
              return [] unless streams_poses?

              tables = {}
              asm = M68000.new(POSES_SENT, holds: Picture::ART)
              asm.label(POSES_SENT)
              @pose_rooms.each do |name, room|
                table = tables[room.poses] ||= "art pose table #{tables.length}"
                past = "#{POSES_SENT} past #{name}"
                asm.move(:l, asm.disp(5, Memory.displacement(room.wanted)), asm.d(0))
                asm.cmp(:l, asm.disp(5, Memory.displacement(room.sent)), asm.d(0))
                asm.branch(:eq, past)
                asm.cmp(:l, asm.imm(room.poses.length), asm.d(0))
                asm.branch(:cc, past) # read with no sign, a pose below nought is past the last
                asm.move(:l, asm.d(0), asm.disp(5, Memory.displacement(room.sent)))
                asm.lsl(:l, 3, asm.d(0)) # eight bytes a pose
                asm.lea(asm.abs_l(table), asm.a(1))
                asm.movea(:l, asm.idx(1, 0, 0), asm.a(0))
                asm.move(:l, asm.idx(1, 4, 0), asm.d(1))
                asm.move(:l, asm.imm(room.first * Art::TILE_BYTES), asm.d(0))
                asm.jsr(asm.abs_l("rt_vram_run_copied"))
                asm.label(past)
              end
              asm.rts
              tables.each do |poses, label|
                asm.label(label)
                poses.each { |name| asm.data_longs(pose_tiles_label(name), @art.cut_tiles(name).length * Art::TILE_BYTES / 2) }
              end
              [asm.section, *pose_tiles_sections(tables.keys.flatten.uniq)]
            end

            def pose_tiles_label(name) = "art pose tiles #{name}"

            # The tiles of each pose +names+, as its room holds them (Art#cut_tiles), a section each.
            def pose_tiles_sections(names)
              names.map do |name|
                asm = M68000.new(pose_tiles_label(name), holds: Picture::ART)
                asm.label(pose_tiles_label(name))
                asm.data_bytes(@art.cut_tiles(name).join.bytes)
                asm.section
              end
            end
          end
        end
      end
    end
  end
end
