# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # Raised when a tool a computer build needs is missing or the wrong version (zig, node), when
        # a build is refused by the compiler, or when the program it made stops with an error.
        class Error < StandardError; end
      end
    end
  end
end
