# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # The game as C, checked against the interpreter on every frame (Computer::Check).
        class CheckedRun < HeadlessRun
          include Computer::Check
          include Differences
          extend Differences
        end
      end
    end
  end
end
