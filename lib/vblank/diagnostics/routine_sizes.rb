# frozen_string_literal: true

module VBlank
  module Diagnostics
    # How many bytes each of the game's routines takes (IR::Backends::RoutineSize), for a profile to
    # print after the measured frames and to carry as data.
    module RoutineSizes
      module_function

      # The twelve biggest routines, and how much of +whole+ (the words after \"in\", such as
      # \"a cartridge of 8 banks\") the game's code is. Nothing for no sizes.
      def render(sizes, out, whole:)
        return if sizes.empty?

        out.puts "", "Your routines by size:"
        sizes.first(12).each { |size| out.puts format("%8d bytes  %s", size.bytes, size.routine) }
        out.puts "In all: #{sizes.sum(&:bytes)} bytes of routines, in #{whole}."
      end

      def as_json(sizes) = { routine_sizes: sizes.map { |size| { routine: size.routine, bytes: size.bytes } } }
    end
  end
end
