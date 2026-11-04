# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHAT A CARTRIDGE LOWERING HOLDS WHILE IT MAKES A ROUTINE, and how to make a routine and leave
      # the lowering as it was. A lowering keeps what it makes as it goes — its labels, the numbers a
      # routine keeps and the work memory they take, the tables, pictures and colours it gathers — in
      # its own instance variables and in a few objects of its own (its Memory, its Art). Two things
      # need that state put back afterwards:
      #
      # - measuring a run of statements (#on_copies): made on copies, and the lowering goes back to
      #   what it had. The copies, not what it had, are what is changed: the work memory is shared
      #   with the build and the runtime, which would see a place reserved only to be measured.
      # - a routine made for real and then found too big for a bank (#snapshot, RoutineCuts#sections):
      #   what it reserved is put back, into the very objects the build holds, and the routine is cut.
      #
      # Which of the lowering's things are which is the lowering's to say, as three lists:
      #
      # - +copied+: classes it changes the insides of as it makes a statement (a palette gaining a
      #   colour), copied all the way down;
      # - +shared+: classes it only reads while it makes a statement, shared as they are: numbers,
      #   names, the program and what is worked out from it before any statement is made;
      # - +unchanged+: instance variables making a statement never changes, left alone: the
      #   statements already cut into parts, what the build worked out once (BuildCache).
      #
      # The lowering's own lists and tables are added to, never changed inside, so a copy of each is
      # enough. Anything else is refused, so a new kind of thing a lowering keeps is never shared with
      # a measurement by mistake.
      class LoweringState
        def initialize(copied:, shared:, unchanged:)
          @copied = copied
          @shared = shared
          @unchanged = unchanged
          Ractor.make_shareable(self) # a lowering's constant, read by builds in any Ractor
        end

        # The block's answer, made on copies of +lowering+'s state, after which the lowering has
        # what it had before.
        def on_copies(lowering)
          saved = held_by(lowering)
          copies(saved).each { |name, copy| lowering.instance_variable_set(name, copy) }
          yield
        ensure
          (lowering.instance_variables - saved.keys).each { |name| lowering.remove_instance_variable(name) }
          saved.each { |name, value| lowering.instance_variable_set(name, value) }
        end

        # +lowering+'s state now, which Snapshot#restore! puts back. A COPIED object's insides are
        # copied, not the object: it is the same object afterwards, and another of the lowering's
        # COPIED objects that holds it still holds that one.
        def snapshot(lowering)
          saved = held_by(lowering)
          kept = saved.except(*@unchanged)
          seen = {}.compare_by_identity
          kept.each_value { |value| seen[value] = value if @copied.any? { |kind| value.is_a?(kind) } }
          insides = kept.to_h do |name, value|
            case value
            when Hash, Array then [name, value.dup]
            when *@copied then [name, value.instance_variables.to_h { |held| [held, deep_copy(value.instance_variable_get(held), seen)] }]
            when *@shared then [name, nil]
            else raise ArgumentError, "#{name} holds a #{value.class}, which a lowering's state neither copies nor shares"
            end
          end
          Snapshot.new(lowering, saved, insides.compact)
        end

        # A lowering's state as it was, put back by #restore!: each of its lists and tables, and the
        # insides of each COPIED object, written back into the same object, so whatever else holds
        # one (the build holds the work memory) sees it put back too.
        class Snapshot
          def initialize(lowering, saved, insides)
            @lowering = lowering
            @saved = saved
            @insides = insides
          end

          def restore!
            (@lowering.instance_variables - @saved.keys).each { |name| @lowering.remove_instance_variable(name) }
            @saved.each do |name, value|
              put_back(value, @insides[name]) if @insides.key?(name) && !value.frozen?
              @lowering.instance_variable_set(name, value)
            end
          end

          private

          def put_back(value, was)
            case value
            when Hash then value.clear.update(was)
            when Array then value.replace(was)
            else
              (value.instance_variables - was.keys).each { |held| value.remove_instance_variable(held) }
              was.each { |held, inside| value.instance_variable_set(held, inside) }
            end
          end
        end

        private

        def held_by(lowering) = lowering.instance_variables.to_h { |name| [name, lowering.instance_variable_get(name)] }

        # A copy of each of +saved+ that making a statement can change, by its name.
        def copies(saved)
          seen = {}.compare_by_identity
          saved.except(*@unchanged).to_h { |name, value| [name, copy_of(name, value, seen)] }
        end

        def copy_of(name, value, seen)
          case value
          when Hash, Array then value.dup
          when *@copied then deep_copy(value, seen)
          when *@shared then value
          else raise ArgumentError, "#{name} holds a #{value.class}, which a lowering's state neither copies nor shares"
          end
        end

        # +value+ copied all the way down, each object once: two things that held one object hold one
        # copy of it.
        def deep_copy(value, seen)
          return seen[value] if seen.key?(value)

          case value
          when Hash then (seen[value] = value.dup).transform_values! { |held| deep_copy(held, seen) }
          when Array then (seen[value] = value.dup).map! { |held| deep_copy(held, seen) }
          when *@copied
            (seen[value] = value.dup).tap do |copy|
              copy.instance_variables.each { |held| copy.instance_variable_set(held, deep_copy(copy.instance_variable_get(held), seen)) }
            end
          else value
          end
        end
      end
    end
  end
end
