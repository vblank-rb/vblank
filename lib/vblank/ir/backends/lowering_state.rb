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
      #   what it reserved is put back, into the very objects the lowering and the build hold.
      #
      # Which of the lowering's things are which is the lowering's to give, as three lists:
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
      #
      # It reads and writes instance variables by name (instance_variable_get and _set) on purpose:
      # what is saved is everything a lowering holds, whatever a later change adds to it, and a list
      # written out by hand would let a new one go unsaved without a word.
      class LoweringState
        def initialize(copied:, shared:, unchanged:)
          @copied = copied
          @shared = shared
          @unchanged = unchanged
          Ractor.make_shareable(self) # a lowering's constant, read by builds in any Ractor
        end

        # The block's answer, made on copies of +lowering+'s state, after which the lowering has
        # what it had before. One object held in two places is one copy held in both.
        def on_copies(lowering)
          saved = instance_values(lowering)
          seen = {}.compare_by_identity
          kept = kept_values(saved)
          kept.each { |_, value| seen[value] = value.dup if role_of(value) == :list }
          kept.each { |name, value| lowering.instance_variable_set(name, copy_of(value, seen)) }
          yield
        ensure
          (lowering.instance_variables - saved.keys).each { |name| lowering.remove_instance_variable(name) }
          saved.each { |name, value| lowering.instance_variable_set(name, value) }
        end

        # +lowering+'s state now, which Snapshot#restore! puts back. What is kept is what each list,
        # table and COPIED object holds, every one reached from the lowering, and #restore! writes it
        # back into the same objects: nothing is swapped for a copy, so whatever holds any of them
        # holds the same object, put back.
        def snapshot(lowering)
          saved = instance_values(lowering)
          held = {}.compare_by_identity
          kept_values(saved).each do |_, value|
            role_of(value) == :list ? held[value] ||= value.dup : note_insides(value, held)
          end
          Snapshot.new(lowering, saved, held)
        end

        # A lowering's state as it was (#snapshot).
        class Snapshot
          def initialize(lowering, saved, held)
            @lowering = lowering
            @saved = saved
            @held = held
          end

          # The lowering, and every list, table and object of its it had, as they were.
          def restore!
            (@lowering.instance_variables - @saved.keys).each { |name| @lowering.remove_instance_variable(name) }
            @saved.each { |name, value| @lowering.instance_variable_set(name, value) }
            @held.each do |object, was|
              next if object.frozen?

              case object
              when Hash then object.clear.update(was)
              when Array then object.replace(was)
              else
                (object.instance_variables - was.keys).each { |name| object.remove_instance_variable(name) }
                was.each { |name, inside| object.instance_variable_set(name, inside) }
              end
            end
          end
        end

        private

        def instance_values(lowering) = lowering.instance_variables.to_h { |name| [name, lowering.instance_variable_get(name)] }

        # +saved+ but what making a statement never changes, each checked to be something this
        # state knows how to keep.
        def kept_values(saved)
          saved.except(*@unchanged).each do |name, value|
            next if role_of(value)

            raise ArgumentError, "#{name} holds a #{value.class}, which a lowering's state neither copies nor shares"
          end
        end

        # :list for a list or table of the lowering's own, :copied, :shared, or nil for none of those.
        def role_of(value)
          case value
          when Hash, Array then :list
          when *@copied then :copied
          when *@shared then :shared
          end
        end

        def copy_of(value, seen)
          case role_of(value)
          when :list then seen.fetch(value)
          when :copied then deep_copy(value, seen)
          else value
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

        # What +value+ holds, and what each list, table and COPIED object inside it holds, all the
        # way down, into +held+: a list or table by a copy of it, an object by its instance variables.
        def note_insides(value, held)
          return if held.key?(value)

          case value
          when Hash
            held[value] = value.dup
            value.each_value { |inside| note_insides(inside, held) }
          when Array
            held[value] = value.dup
            value.each { |inside| note_insides(inside, held) }
          when *@copied
            held[value] = value.instance_variables.to_h { |name| [name, value.instance_variable_get(name)] }
            held[value].each_value { |inside| note_insides(inside, held) }
          end
        end
      end
    end
  end
end
