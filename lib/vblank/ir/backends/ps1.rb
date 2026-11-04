# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # Raised when a program cannot be made into a PlayStation program: it reaches something the
        # PlayStation cannot do, or something its build does not make yet, or it is too big for the
        # console's memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "ps1/r3000"
require_relative "ps1/linker"
