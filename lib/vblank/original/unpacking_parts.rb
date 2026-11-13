# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # WHICH SLOTS A PART OF AN UNPACKING ROUTINE READS AND WRITES, by name, recorded as the part is
    # built (SlotBytes#record_read, #record_write): what tells UnpackingParts which parts read what
    # another wrote.
    class SlotUses
      attr_reader :read, :written

      def initialize
        @read = Set.new
        @written = Set.new
      end

      def record_read(name) = @read << name
      def record_write(name) = @written << name
    end

    # THE PARTS OF AN UNPACKING ROUTINE (`slots.fill_from_copy :music do ... end`, one block a
    # part), as the pack cache keeps them apart (PackCache#pack). Each part is built once more as
    # a program of its own, the slots copied as they are and that part alone, to learn what it
    # reads and writes; the parts are then played as programs of the parts asked for and nothing
    # else (#unpacking_of), which run in the order the game gave them, as the whole routine does.
    #
    # WHAT A PART NEEDS BEFORE IT (#inputs_of). A part reads only the copy, the slots and the
    # variables, lists and routines it names. So it needs an earlier part played before it when
    # that part writes a slot it reads or writes too (SlotUses), or names a variable, list, table
    # or routine it names too (+names+). The second is conservative: two parts that each set a
    # variable of the same name before reading it need nothing of each other, and are played
    # together all the same. What the routine's building blocks name for themselves
    # (`__unpacking__`, the copy's verbs and formats, whose state each call sets before it reads)
    # and the counter of a `repeat` (set as the loop starts) are left out, or every part would
    # need every other.
    #
    # A part is played with all it needs, so the slots it writes are those the whole routine
    # writes, byte for byte. The cost is that a part changed alone plays again what it reads from
    # too, though that part's slots are in the cache.
    #
    # WHAT THIS CANNOT SEE. Only what the program holds is looked at. Ruby the parts' blocks share
    # as the game is built (an instance variable set in one block, a local both close over) can
    # make a part build differently alone than after the others, and the count of bytes done
    # (CopyReader#bytes_done) runs on from one part to the next. A part that hands anything to
    # another this way must hand it through a slot instead.
    #
    # WHAT A PART'S CACHE KEY IS MADE OF (#key_source): the program of the part built alone, for each
    # part played to make it (#played_for), as digests of each one's text as the pack cache keys a
    # program (PackCache.program_source). A part's blocks
    # run as the same DSL calls however many parts are built with them, so the program of a part
    # and those it needs changes only when one of their programs alone does. Building that program
    # for each part's key instead built a port's routine again for every part, and for a port of
    # many parts that cost more than playing it.
    class UnpackingParts
      # A part: its name, the slot names it reads and writes (Sets), the names of variables, lists,
      # tables and routines it names besides the building blocks' (#names_in), and a digest of its
      # program built alone (#key_source).
      Part = Data.define(:name, :read, :written, :names, :program_digest)

      # Names a part's program holds that carry nothing from one part to the next: the building
      # blocks' own (Messages::MadeNames' :unpacking_part), and a `repeat`'s counter.
      UNSHARED_NAME_PATTERN = /\A__(unpacking__|repeat_\d+\z)/

      # +parts+ (each a Part) in the order they run; +make_unpacking+ makes the Unpacking of a
      # list of part names, playing those parts in the order they run and no others. +whole+ is the
      # Unpacking of every part, where the caller has built it already, so it is not built again.
      def initialize(parts:, make_unpacking:, whole: nil)
        @parts = parts
        @make_unpacking = make_unpacking
        @unpackings = whole ? { names => whole } : {}
      end

      # The digest of a part's program built alone (+program+): what its Part keeps for #key_source.
      def self.program_digest(program) = Digest::SHA256.hexdigest(PackCache.program_source(program))

      # Every name +program+ holds of a variable, list, table or routine, but UNSHARED_NAME_PATTERN: the
      # operands its kinds declare as names (IR::Node#named_operands).
      def self.names_in(program)
        program.walk.each_with_object(Set.new) do |node, names|
          node.named_operands.each do |field, value|
            next unless node.class.tags[field] == :name && value.is_a?(Symbol) && !value.match?(UNSHARED_NAME_PATTERN)

            names << value
          end
        end
      end

      # The names of the parts, in the order they run.
      def names = @parts.map(&:name)

      # The parts that must be played before the part +name+ for it to write what the whole
      # routine writes: those it needs, and all they need, in the order they run.
      def inputs_of(name)
        needed = Set.new
        waiting = [name]
        until waiting.empty?
          part = part_named(waiting.pop)
          earlier_parts(part).each do |earlier|
            waiting << earlier.name if needs?(part, earlier) && needed.add?(earlier.name)
          end
        end
        names.select { |each| needed.include?(each) }
      end

      # The parts played to make the slots of the parts +wanted+: each of them, and every part they
      # need (#inputs_of), in the order they run.
      def played_for(wanted)
        played = wanted.flat_map { |name| [name, *inputs_of(name)] }.to_set
        names.select { |name| played.include?(name) }
      end

      # The Unpacking playing the parts +played+ (names, in the order they run) and no others.
      def unpacking_of(played) = @unpackings[played] ||= @make_unpacking.call(played)

      # The text a part's cache key holds for the programs that make its slots: each part played
      # to make them (#played_for), in the order they run, by name and the digest of its program
      # built alone. A change to any of them changes it.
      def key_source(name)
        played_for([name]).map { |each| "#{each} #{part_named(each).program_digest}\n" }.join
      end

      # The names of the slots whose bytes in the pack are what the part +name+ wrote: those it is
      # the last part to write, in the pack's order of its record. A slot a later part writes too
      # is left out, since a run of both holds only the later part's bytes. Which slots these are
      # depends on the parts after it, so the part's key holds them (PackCache#part_entry_path).
      def slots_of(name) = part_named(name).written.select { |slot| last_writer_of(slot) == name }.sort

      # The name of the last part that writes the slot +slot_name+, or nil where no part does.
      def last_writer_of(slot_name) = @parts.reverse.find { |part| part.written.include?(slot_name) }&.name

      private

      def part_named(name) = @parts.find { |part| part.name == name }

      def earlier_parts(part) = @parts.take(@parts.index(part))

      def needs?(part, earlier)
        earlier.written.intersect?(part.read | part.written) || earlier.names.intersect?(part.names)
      end
    end
  end
end
