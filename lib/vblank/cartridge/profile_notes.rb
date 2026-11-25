# frozen_string_literal: true

module VBlank
  module Cartridge
    # What the build noted for a cartridge's profile to tell before the measured frames
    # (Diagnostics::BuildNotes): the variables the build added that the author never declared
    # (Diagnostics::HiddenVariables), the counted loops of game code and what the build made of each
    # (Diagnostics::CountedLoops), and the numbers kept in instance variables
    # (Diagnostics::InstanceVariableNumbers). They are the builder's to know, not a console's, so
    # `VBlank.build` hands them to whichever cartridge it made.
    module ProfileNotes
      attr_writer :hidden_variables, :counted_loops, :instance_variable_numbers

      def hidden_variables = @hidden_variables || []
      def counted_loops = @counted_loops || []
      def instance_variable_numbers = @instance_variable_numbers || []

      # The notes, and how many bytes each of the game's routines takes, biggest first (its places'
      # +routine_sizes+), or none for a cartridge with no record of its build. For a cartridge whose
      # +built+ is a lowering's places.
      module WithRoutineSizes
        include ProfileNotes

        def routine_sizes = @built ? @built.routine_sizes : []
      end
    end
  end
end
