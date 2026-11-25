# frozen_string_literal: true

module VBlank
  module Diagnostics
    # What a build noted that a profile tells before the measured frames: the variables the author
    # never declared, the counted loops, and the numbers kept in instance variables. A ROM that
    # keeps none of them tells nothing.
    module BuildNotes
      module_function

      def render(rom, out)
        printer = IR::Printer.for(out)
        HiddenVariables.render(rom, printer)
        CountedLoops.render(rom, printer)
        InstanceVariableNumbers.render(rom, printer)
      end

      # The same notes as data, for `rom.profile(format: :json)`.
      def as_json(rom)
        HiddenVariables.as_json(rom).merge(CountedLoops.as_json(rom)).merge(InstanceVariableNumbers.as_json(rom))
      end
    end
  end
end
