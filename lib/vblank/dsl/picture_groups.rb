# frozen_string_literal: true

module VBlank
  module DSL
    # Sprite pictures in groups
    #
    # `picture_groups` puts a scene's sprite pictures in numbered groups, such as one group for
    # each room of a scene made of many rooms. Only the groups that are up take sprite memory,
    # so a scene can have many more pictures than the console holds at once. The game says
    # which groups are up with #show, from numbers it works out: the room it is in, and the
    # room beside while the screen slides.
    #
    # ```ruby
    # rooms = picture_groups :rooms, { 0 => [:pot, :bush], 1 => [:pot, :chest] }, up_together: [[0, 1]]
    # rooms.show room
    # ```
    class PictureGroups
      # The name the groups were given.
      attr_reader :name

      # +slots+ is how many groups can be up at once: the biggest set up_together names.
      def initialize(builder, name, slots:)
        @builder = builder
        @name = name
        @slots = slots
      end

      # Sets which groups are up from now on, and returns nil.
      #
      # Give one number for each group to be up, as many as the biggest set in `up_together:`
      # lets be up at once. Each is a number, a variable or an expression. A number naming no
      # group is a room with no things of its own, and nothing of it is up.
      #
      # ```ruby
      # rooms.show here            # one group up
      # rooms.show here, beside    # two, while the screen slides from one room to the next
      # ```
      def show(*numbers)
        refuse_count_of_groups!(numbers)
        refuse_fractions!(numbers)
        @slots.times do |slot|
          which = Value.node_for(numbers.fetch(slot, IR::Nodes::PictureGroups::NONE))
          @builder.record_statement(IR::Build.show_picture_group(@name, slot: slot, which: which))
        end
        nil
      end

      private

      # A group's number is a whole number; a number with a fraction is kept multiplied up, and
      # would name some other group.
      def refuse_fractions!(numbers)
        fraction = numbers.find { |number| number.is_a?(Value) && number.fraction? }
        return unless fraction

        raise ArgumentError, "`show` on :#{@name} was given a number with a fraction. A group's number is a whole " \
                             "number. To fix this, give it a whole number, like `#{@name}.show room.to_i`."
      end

      # At least one group, and no more than can be up at once.
      def refuse_count_of_groups!(numbers)
        return if numbers.length.between?(1, @slots)

        if numbers.empty?
          raise ArgumentError, "`show` on :#{@name} was given no group. Give it the number of the group to show, " \
                               "like `#{@name}.show room`."
        end

        raise ArgumentError,
              "`show` on :#{@name} was given #{count_words(numbers.length)}, and up_together: lets at most " \
              "#{count_words(@slots)} of :#{@name} be up at once. To fix this, show fewer groups, or add a set " \
              "of #{numbers.length} groups to up_together:."
      end

      def count_words(count)
        words = %w[no one two three four five six seven eight nine]
        "#{words.fetch(count, count.to_s)} group#{'s' unless count == 1}"
      end
    end
  end
end
