# frozen_string_literal: true

module VBlank
  module DSL
    # Which way a game's `sort!` or `sort_by!` puts an Array, read from what its block gives.
    #
    # A console sorts by a number, the smallest first or the biggest first, so a block is read
    # once while building, handed stand-ins, and what it gives back says which: `a <=> b` or
    # `b <=> a` for `sort!`, the key or minus the key for `sort_by!`. Any other block is
    # refused, saying what works. DSL::List and DSL::StructArray sort by it.
    module SortOrder # :nodoc: all
      # A stand-in for one of the two things `sort!` compares.
      Probe = Struct.new(:side) do
        def <=>(other) = Compared.new(left: side, right: other.side)
      end

      # What `a <=> b` gave with two stand-ins: which was on the left.
      Compared = Data.define(:left, :right)

      # One field a sort orders by: its name, and whether the biggest comes first.
      Field = Data.define(:name, :descending)

      # What a sort orders by: fields, the first deciding and each after it breaking the ties of
      # those before, as Ruby orders by an Array key (`sort_by! { |s| [s.y, -s.x] }`). A Struct's
      # `<=>` that compares fields gives one of these too, so every way a game says an order is
      # sorted the same way (Pool#declare_sort).
      Key = Data.define(:fields) do
        # The same order back to front, for `reverse!` after a sort: every field turned round.
        def reversed = with(fields: fields.map { |field| field.with(descending: !field.descending) })

        # The key spelled out for a routine's name: each field and its way, `y_up_x_down`.
        def spelling = fields.map { |field| "#{field.name}_#{field.descending ? 'down' : 'up'}" }.join("_")
      end

      # One line's sort: the Key it sorts by, and the line it is written on.
      SortRoutine = Data.define(:key, :line)

      # The routines that sort one Array, one for each line and Key, and how many calls each has.
      # A routine is declared the first time a line asks for it, and taken back once no call is
      # left: `reverse!` moves the call it follows to the routine with the key turned round.
      class Routines
        # +array+ names the Array in the routines' names. The block declares the routine +name+
        # that sorts by +key+.
        def initialize(builder, array, &declare)
          @builder = builder
          @array = array
          @declare = declare
          @routines = {}
          @calls = Hash.new(0)
        end

        # Calls the routine that sorts by +key+ for +line+.
        def call(key, line) = @builder.call(routine_for(key, line))

        # `reverse!` right after a sort of this Array: that sort's call now calls the routine with
        # every field turned round. Refused anywhere else, naming +local+.
        def reverse_last!(local)
          sorted = @builder.last_recorded_statement
          routine = sorted && sorted.kind == :call && @routines[sorted.target]
          SortOrder.refuse_reverse_not_after_sort!(local) unless routine

          was = sorted.target
          sorted.target = routine_for(routine.key.reversed, routine.line)
          forget(was)
        end

        private

        def routine_for(key, line)
          name = SortOrder.routine_name(@array, line, key)
          unless @routines.key?(name)
            @routines[name] = SortRoutine.new(key, line)
            @declare.call(name, key)
          end
          @calls[name] += 1
          name
        end

        def forget(name)
          return unless (@calls[name] -= 1).zero?

          @routines.delete(name)
          @builder.forget_routine(name)
        end
      end

      module_function

      # The line of the game being built, as a number, for a sort's routine name.
      def author_line = Messages::AuthorSource.author_file_and_line.to_s[/:(\d+)\z/, 1].to_i

      # The name of the routine that sorts +array+ by +key+ for +line+ (Messages::MadeNames
      # `array_sort`). The whole key is in it, so two sorts on one line by different keys are two.
      def routine_name(array, line, key)
        Messages::MadeNames.make(:array_sort, array: array, line: line.to_s, order: key.spelling)
      end

      # The Key of an Array of numbers sorted by the items themselves.
      def item_key(descending) = Key.new(fields: [Field.new(name: :item, descending: descending)])

      # The Key `sort_by!`'s block gives when handed +probe+: a number, minus a number, or an
      # Array of those for ties. The block yields each number's node and gives back the name of
      # the field it reads, or nil for one that reads no field. Any other answer is refused.
      def key_from(probe, block, &field_named)
        answer = block.call(probe)
        parts = answer.is_a?(Array) ? answer : [answer]
        fields = parts.map { |part| key_field(part, &field_named) }
        refuse_unknown_key! if fields.empty? || fields.any?(&:nil?)

        Key.new(fields: fields)
      end

      # One number of a key: a field, or minus one for the biggest first.
      def key_field(part)
        node = part.is_a?(Value) ? part.node : nil
        return nil unless node

        name = yield(node)
        return Field.new(name: name, descending: false) if name
        return nil unless node.kind == :neg

        name = yield(node.operand)
        Field.new(name: name, descending: true) if name
      end

      def refuse_unknown_key!
        PlainRuby::Steps.refuse_game_code!("`sort_by!` sorts by one number. This block gives something else. To fix " \
                                           "this, give the number to sort by, `{ |s| s.y }`, or minus it for the " \
                                           "biggest first, `{ |s| -s.y }`. An Array of Structs also takes an Array " \
                                           "of fields, where each field after the first breaks the ties: " \
                                           "`{ |s| [s.y, -s.x] }`.")
      end

      # Does the comparing block of `sort!` put the biggest first? `{ |a, b| b <=> a }` does.
      def descending_by_comparison?(block)
        answer = begin
          block.call(Probe.new(:first), Probe.new(:second))
        rescue NoMethodError, TypeError
          nil
        end
        return false if answer == Compared.new(left: :first, right: :second)
        return true if answer == Compared.new(left: :second, right: :first)

        PlainRuby::Steps.refuse_game_code!("A game sorts by a number, the smallest or the biggest first. This block " \
                                           "compares in another way. To fix this, write `sort!`, " \
                                           "`sort! { |a, b| b <=> a }` for the biggest first, or `sort_by!` with " \
                                           "the number to sort by.")
      end

      def refuse_new_array!(local, verb)
        PlainRuby::Steps.refuse_game_code!("`#{verb}` makes a new Array, and a console keeps no room for one. To fix " \
                                           "this, sort `#{local}` in place with `#{verb}!`.")
      end

      def refuse_reverse_not_after_sort!(local)
        PlainRuby::Steps.refuse_game_code!("`reverse!` on `#{local}` works only right after `sort!` or `sort_by!`, " \
                                           "where it puts the biggest first. To fix this, write it there, or sort " \
                                           "with `sort! { |a, b| b <=> a }`.")
      end
    end
  end
end
