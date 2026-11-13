# frozen_string_literal: true

require "minitest/ractor"

module VBlank
  module Testing
    # A GAME'S TESTS PLAYED IN RACTORS, set up from its test helper in one line:
    #
    #   require "vblank/testing/in_ractors"
    #   class Minitest::Test
    #     include VBlank::Testing::InRactors
    #   end
    #
    # Ractors are Ruby's way of using every core in one process: minitest-ractor plays each test in
    # one, and a test that reaches state the whole process shares is reported rather than tolerated.
    # The Rakefile does its half (RactorSettings). Including this:
    #
    # - hands every test class to the pool (minitest runs a class serially until it asks not to);
    # - freezes every fixture a test class keeps in a constant, all the way down (FrozenConstants);
    # - gives each class `read_once(name) { ... }`, a fixture made once in each Ractor, for what
    #   cannot be frozen or must stay with the core that made it (a file handle, a booted console).
    #
    # A file whose tests change the whole process on purpose (registering something, declaring a
    # class) or start a child process, which hangs inside a Ractor, writes minitest-ractor's own
    # `runs_on_the_main_ractor!` at the top, with a line saying why.
    #
    # It needs a minitest-ractor that makes minitest's own state shareable (Minitest::Ractor::
    # ShareableConstants, which covers Minitest::Assertions.diff): one before that crashes a test
    # whose long comparison fails, looking for a diff program from inside a Ractor.
    module InRactors
      def self.included(test_class)
        super
        test_class.extend(FrozenConstants)
        test_class.extend(ReadOnce)
        test_class.parallelize_me!
      end

      # EVERY FIXTURE A TEST CLASS PARKS IN A CONSTANT IS FROZEN, ALL THE WAY DOWN, the moment it
      # is declared. Ruby tells a class when a constant is added to it, so there is nothing to
      # remember and nothing to repeat.
      #
      # It buys two things. A fixture shared by the tests in a file can no longer be changed by one
      # of them and read changed by the next, a real bug that is invisible until the day test order
      # moves. And a test in a Ractor may read a constant only when nothing in it can change.
      #
      # TWO THINGS ARE LEFT ALONE. A nested module or class, because that is code rather than a
      # fixture. And a STREAM (a file, a socket, $stdout), because freezing one works and then
      # nothing can write to it again: a test that parked $stdout in a constant would take the whole
      # run down, with an error pointing somewhere else entirely.
      #
      # A block that reaches for a variable around it can never be shared, and is left as it was:
      # the Ractor run names the test that reads it. Freezing a block hands back a new one rather
      # than changing the old, so that case has to put the constant back, which re-enters here and
      # finds it shared already. A String is interned as well (InRactors.shareable says why).
      module FrozenConstants
        def const_added(name)
          super
          InRactors.share_constant(self, name)
        end
      end

      # A FIXTURE AS EVERY RACTOR MAY READ IT: +value+ frozen all the way down, and a String
      # interned besides (`-value`), which is what keeps its bytes when a test writes it out.
      #
      # RUBY'S IO WRITES A FROZEN STRING OF A FEW HUNDRED BYTES BY MOVING ITS BYTES. The first time
      # such a String is written (File.binwrite, IO#write), Ruby (4.0) hands a hidden String its
      # bytes and points the String itself at the hidden one: ObjectSpace.dump calls it "shared"
      # afterwards. That changes the fixture, which every Ractor shares, from whichever Ractor
      # writes it. Two Ractors writing the same fixture for the first time at the same moment each
      # make a hidden String, the fixture is left pointing at one of them, and the garbage
      # collector frees the other, and with it the bytes the fixture still reads. The fixture then
      # holds whatever the memory is used for next: a made-up original written to disk reads back
      # with another digest, a different one each run, and only when the tests happen to start
      # together. Ruby copies the bytes of an interned String instead of moving them, so an
      # interned fixture is never changed by a write.
      #
      # A String inside an Array, a plain Hash or a plain Data is interned too, the fixture built
      # again around it, since a test may write one of those as well (#rebuildable? says which can
      # be built again unchanged). One inside any other object is frozen as it was, so a fixture a
      # test writes to a file is a String, or held in one of those.
      def self.shareable(value)
        return value if Ractor.shareable?(value) && !holds_string_to_intern?(value)

        Ractor.make_shareable(with_strings_interned(value))
      end

      # +value+ with every String in it, and in the Arrays, Hashes and Data in it, interned. +seen+
      # holds the containers already walked, so a fixture that holds itself is walked once.
      def self.with_strings_interned(value, seen = {}.compare_by_identity)
        return internable?(value) ? -value : value if value.is_a?(String)
        return value if seen.key?(value) || !rebuildable?(value)

        seen[value] = true
        case value
        when Array then value.map { |item| with_strings_interned(item, seen) }
        when Hash then value.to_h { |key, item| [with_strings_interned(key, seen), with_strings_interned(item, seen)] }
        else value.with(**value.to_h.transform_values { |item| with_strings_interned(item, seen) })
        end
      end

      # Whether +value+ holds a String that is not interned, where #with_strings_interned would find it.
      def self.holds_string_to_intern?(value, seen = {}.compare_by_identity)
        return internable?(value) && !value.equal?(-value) if value.is_a?(String)
        return false if seen.key?(value) || !rebuildable?(value)

        seen[value] = true
        parts = value.is_a?(Array) ? value : value.to_h.to_a.flatten(1)
        parts.any? { |part| holds_string_to_intern?(part, seen) }
      end

      # Whether +value+ is a container #with_strings_interned can build again with nothing changed
      # but its Strings: an Array; a Hash with no default and keys compared by value, since `to_h`
      # loses the rest; a Data whose class keeps Data's own initialize, since `with` hands one of
      # its own keywords it may not take, and it may copy the Strings it is given.
      def self.rebuildable?(value)
        case value
        when Array then true
        when Hash then value.default.nil? && value.default_proc.nil? && !value.compare_by_identity?
        when Data then value.class.instance_method(:initialize).owner == Data
        else false
        end
      end

      # Whether +string+ is one `-` interns: a plain String with no instance variables. Ruby hands
      # back a fresh copy of any other each time, which is never the interned one.
      def self.internable?(string) = string.instance_of?(String) && string.instance_variables.empty?

      private_class_method :with_strings_interned, :holds_string_to_intern?, :rebuildable?, :internable?

      # Every constant of +fixtures+, a module of fixtures shared by several test files, made
      # shareable as a test class's are: for the module's last line, once all are declared.
      def self.share_constants(fixtures)
        fixtures.constants(false).each { |name| share_constant(fixtures, name) }
      end

      # Constant +name+ of +holder+ made shareable (.shareable), put back where that made it a new
      # object.
      def self.share_constant(holder, name)
        value = holder.const_get(name, false)
        return if value.is_a?(Module) || value.is_a?(IO)

        shareable = shareable(value)
        return if shareable.equal?(value)

        holder.module_exec(name) { |named| remove_const(named) }
        holder.const_set(name, shareable)
      rescue Ractor::IsolationError
        nil
      end

      # A FIXTURE MADE ONCE IN EACH RACTOR, kept under the class's name and +name+, for what cannot
      # be frozen. It is made as many times as there are workers, so it is for what is cheap or
      # cannot be shared; anything dear that can be frozen belongs in a constant.
      module ReadOnce
        def read_once(name) = ::Ractor.current[:"#{self}.#{name}"] ||= yield
      end
    end
  end
end
