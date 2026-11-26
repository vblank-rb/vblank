# frozen_string_literal: true

module VBlank
  class Builder
    # Tables in groups
    #
    # A game whose data is more than the console can hold at once keeps each level's tables in a
    # group of their own, and loads the group of the level it is on. Only the tables of the group
    # loaded need room, as the console's own games loaded a level's data when the level began and let
    # the last level's go. On a cartridge every table is always there, so loading costs nothing; on a
    # PlayStation the groups wait on the disc, and loading one reads it into memory.
    #
    # ```ruby picture=still
    # VBlank.game "LEVELS", consoles: %i[gba] do
    #   screen :bitmap
    #   forest = table :forest, [2, 4, 6, 8]
    #   cave = table :cave, [9, 7, 5, 3]
    #   levels = table_groups :levels, { 0 => [:forest], 1 => [:cave] }
    #   # the forest's numbers are in; the cave's take no room until group 1 is loaded
    #   levels.load 0
    #   fill_rect 0, 0, forest[3] * 10, 20, :green
    #   levels.load 1
    #   fill_rect 0, 30, cave[0] * 10, 20, :blue
    #   game_loop {}
    # end
    # ```
    #--
    # A concern of Builder, mixed in so `table_groups` stays a flat DSL verb.
    #++
    module TableGroups
      # Groups tables by level, and returns a handle to say which group is loaded.
      #
      # A table in no group is there the whole time. A table in a group can be read only while its
      # group is loaded. Reading it at any other moment is a mistake, and the game stops with a plain
      # error on every build. No group is loaded until the game loads one.
      #
      # ```ruby
      # levels = table_groups :levels, { 0 => [:forest_map, :birds], 1 => [:cave_map, :birds] }
      # levels.load level              # this level's tables are in; the last level's are gone
      # ```
      #
      # * `name` - what the groups are called, in errors and reports.
      # * `groups` - each group's tables, as a hash from the group's number to a list of names. A
      #   table can be in more than one group of one set, and in one set only.
      def table_groups(name, groups)
        refuse_table_groups_named_twice!(name)
        refuse_table_groups_shape!(name, groups)
        refuse_table_in_two_sets!(name, groups)
        numbered = Array.new(groups.keys.max + 1) { |number| groups[number]&.uniq }
        node = Build.table_groups(name, groups: numbered)
        record(node)
        @table_groups[name] = node
        DSL::TableGroups.new(self, name)
      end

      private

      def refuse_table_groups_named_twice!(name)
        return unless @table_groups.key?(name)

        raise ArgumentError, "table_groups :#{name} is declared twice. Each set of groups needs its own name. " \
                             "To fix this, rename one of them."
      end

      def refuse_table_groups_shape!(name, groups)
        whole = ->(number) { number.is_a?(Integer) && number >= 0 }
        return if groups.is_a?(Hash) && !groups.empty? &&
                  groups.all? { |number, tables| whole.call(number) && tables.is_a?(Array) && tables.all?(Symbol) }

        raise ArgumentError, "table_groups :#{name} was given #{groups.inspect}. It needs each group's number " \
                             "with the names of its tables, like `table_groups :#{name}, { 0 => [:forest], 1 => [:cave] }`."
      end

      # A set of groups shares one room: a table in two sets would need a place in each.
      def refuse_table_in_two_sets!(name, groups)
        groups.values.flatten.uniq.each do |table|
          other = @table_groups.values.find { |node| node.tables.include?(table) } or next

          raise ArgumentError, "table_groups :#{name} names :#{table}, and table_groups :#{other.name} names it " \
                               "too. A table can be in one set of groups only. To fix this, put :#{table} in the " \
                               "groups of one set, or make a second table of the same numbers."
        end
      end

      # Once every table is declared: every table a group names is one, checked here and not where
      # the groups are written, since a game may group its tables before it declares them.
      def finalize_table_groups
        @table_groups.each_value do |node|
          node.tables.each do |table|
            next if declared_table?(table)

            raise ArgumentError, "table_groups :#{node.name} names :#{table}, which is not a table. " \
                                 "Declare it with `table :#{table}, ...`, or correct the name."
          end
        end
      end

      def declared_table?(name) = @program.walk.any? { |node| node.kind == :table && node.name == name }
    end
  end
end
