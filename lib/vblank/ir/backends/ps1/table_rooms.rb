# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # Where a game's tables in groups (`table_groups`) go: each group on the disc, and each set of
        # groups one room in RAM that the group loaded fills.
        #
        # A PlayStation game's data is far bigger than its 2 megabytes of RAM. The console's own games
        # kept a level's data on the disc and read it into memory when the level began, over the last
        # level's (psx-spx, "CDROM Controller"; the read is Runtime::Disc). So here every set of table
        # groups has one room in RAM, as big as its biggest group, and each group is kept on the disc
        # as the room's bytes with that group in it. Loading a group reads those bytes into the room.
        #
        # A table has one place in the room for every group it is in, so the code that reads it is the
        # same whichever of its groups is loaded. Two tables share bytes of the room only when no group
        # holds both, since then they are never in at once; placed the biggest first, each at the
        # lowest place free of every table it shares a group with.
        #
        # Only the tables the game reads are kept (LoweringPlan#tables_read), each as the program would
        # keep it (LoweringPlan#table_keeping).
        class TableRooms
          SECTOR = Cartridge::PS1Disc::SECTOR

          # One set of groups: its +name+, where its room is in RAM (nil until #place) and how many +bytes+
          # it takes, each table's +offsets+ in the room, and each group as +groups+ (nil for a number
          # naming none, or a Group).
          Room = Data.define(:name, :address, :bytes, :offsets, :groups)

          # One group on the disc: its bytes, laid out as the room holds them, and the sector they start at.
          Group = Data.define(:image, :first_sector) do
            def sectors = Cartridge::PS1Disc.sectors_for(image.bytesize)
          end

          attr_reader :rooms

          # +program+'s sets of table groups, with the tables +plan+ (a LoweringPlan) says the game reads.
          def initialize(program, plan)
            @plan = plan
            read = plan.tables_read.to_h { |table| [table.name, table] }
            @next_sector = Cartridge::PS1Disc::DATA_AT
            @rooms = program.walk.select { |node| node.kind == :table_groups }.map { |node| room_for(node, read) }
          end

          # Whether the game keeps any table in a group, and so is built as a disc.
          def any? = @rooms.any? { |room| room.bytes.positive? }

          # The room the table +name+ is kept in, or nil for a table in no group.
          def room_of(name) = @rooms.find { |room| room.offsets.key?(name) }

          # The room of the set of groups +name+.
          def room_named(name) = @rooms.find { |room| room.name == name }

          # The address of the table +name+ while a group holding it is loaded.
          def address_of(name)
            room = room_of(name)
            room.address + room.offsets.fetch(name)
          end

          # Gives every room its place in +memory+, at the top of the program's room.
          def place(memory)
            @rooms = @rooms.map do |room|
              room.bytes.positive? ? room.with(address: memory.reserve_top("the tables of table_groups :#{room.name}", room.bytes)) : room
            end
          end

          # The program's data on the disc, from Cartridge::PS1Disc::DATA_AT on: each group's bytes, a whole
          # number of sectors each.
          def disc_data
            @rooms.flat_map { |room| room.groups.compact }.map { |group| group.image.ljust(group.sectors * SECTOR, "\0") }.join
          end

          # The words the runtime reads a group of +room+ by, for each group number: where it starts on the
          # disc, as the minute, second and sector the drive's Setloc takes (psx-spx, "CDROM Controller
          # Command Summary"), a byte each in BCD from the low byte up; then how many sectors it takes.
          # Nought sectors for a number naming no group.
          def entries(room)
            room.groups.flat_map do |group|
              next [0, 0] if group.nil?

              minute, second, frame = Cartridge::CDSector.header(group.first_sector).bytes.first(3)
              [minute | (second << 8) | (frame << 16), group.sectors]
            end
          end

          private

          def room_for(node, read)
            tables = node.tables.select { |name| read.key?(name) }.map { |name| read.fetch(name) }
            sizes = tables.to_h { |table| [table.name, (bytes_of(table).bytesize + 3) & ~3] }
            offsets = {}
            tables.sort_by { |table| [-sizes.fetch(table.name), table.name.to_s] }.each do |table|
              offsets[table.name] = lowest_free(table.name, sizes, offsets, node)
            end
            room_bytes = offsets.map { |name, at| at + sizes.fetch(name) }.max || 0
            groups = node.groups.map do |names|
              next nil if names.nil?

              image = "\0".b * offsets.select { |name, _| names.include?(name) }.map { |name, at| at + sizes.fetch(name) }.max.to_i
              names.each do |name|
                table = read[name] or next
                image[offsets.fetch(name), bytes_of(table).bytesize] = bytes_of(table)
              end
              Group.new(image: image, first_sector: @next_sector).tap { |group| @next_sector += group.sectors }
            end
            Room.new(name: node.name, address: nil, bytes: Cartridge::PS1Disc.sectors_for(room_bytes) * SECTOR, offsets: offsets,
                     groups: groups)
          end

          # The lowest place, a word apart, where +name+ overlaps none of the tables placed already that
          # some group of +node+ holds with it.
          def lowest_free(name, sizes, offsets, node)
            together = node.groups.compact.select { |names| names.include?(name) }.flatten.uniq - [name]
            taken = offsets.select { |other, _| together.include?(other) }.map { |other, at| [at, at + sizes.fetch(other)] }.sort
            at = 0
            taken.each { |first, past| at = past if at + sizes.fetch(name) > first && at < past }
            at
          end

          # The table's entries as the program keeps them, the low byte first (Lowering#table_sections).
          def bytes_of(table)
            (@bytes ||= {})[table.name] ||= begin
              bytes = Runtime::Lists::EntryKeeping.of(@plan.table_keeping(table)).bytes
              table.values.flat_map { |entry| Array.new(bytes) { |i| (Int32.wrap(entry) >> (8 * i)) & 0xFF } }.pack("C*")
            end
          end
        end
      end
    end
  end
end
