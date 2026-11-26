# frozen_string_literal: true

module VBlank
  module DSL
    # Tables in groups
    #
    # `table_groups` puts a game's tables in numbered groups, such as one group for each level.
    # Only the group loaded takes room, so a game can have much more data than the console holds at
    # once. The game says which group is loaded with #load, from a number it works out: the level it
    # is on.
    #
    # ```ruby
    # levels = table_groups :levels, { 0 => [:forest_map], 1 => [:cave_map] }
    # levels.load level
    # ```
    class TableGroups
      # The name the groups were given.
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # Loads group +which+ in place of the group that was loaded, and returns nil.
      #
      # +which+ is a number, a variable or an expression. A number naming no group leaves no group
      # loaded. On a console that keeps its groups on a disc, the game waits while the group is read:
      # about a third of a second for each 100K, as a level loaded on the console's own games.
      #
      # ```ruby
      # levels.load level
      # ```
      def load(which)
        refuse_fraction!(which)
        @builder.record_statement(IR::Build.load_table_group(@name, which: Value.node_for(which)))
        nil
      end

      private

      # A group's number is a whole number; a number with a fraction is kept multiplied up, and would
      # name some other group.
      def refuse_fraction!(which)
        return unless which.is_a?(Value) && which.fraction?

        raise ArgumentError, "`load` on :#{@name} was given a number with a fraction. A group's number is a whole " \
                             "number. To fix this, give it a whole number, like `#{@name}.load level.to_i`."
      end
    end
  end
end
