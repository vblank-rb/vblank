# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # Raised when a program cannot be made into a Genesis cartridge: it reaches something the
        # Genesis cannot do, or something its build does not make yet, or it is too big for the
        # cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "genesis/m68000"
require_relative "genesis/linker"
