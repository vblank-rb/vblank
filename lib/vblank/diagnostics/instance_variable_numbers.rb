# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The numbers a game keeps in instance variables (DSL::PlainRuby::InstanceVariables), each with
    # the name a profile and a test read it by, and whose instance variable it is.
    module InstanceVariableNumbers
      module_function

      def render(rom, printer)
        notes = rom.respond_to?(:instance_variable_numbers) ? rom.instance_variable_numbers : []
        return if notes.empty?

        printer.puts("instance variables the game keeps: #{notes.length}")
        notes.each { |note| printer.puts("  #{note.name}  #{note.label} of #{note.part}") }
        printer.puts("")
      end

      # The same list as data, for `rom.profile(format: :json)`.
      def as_json(rom)
        notes = rom.instance_variable_numbers
        { instance_variables: notes.map { |note| { name: note.name, label: note.label, part: note.part } } }
      end
    end
  end
end
