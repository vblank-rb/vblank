# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # Game code gave a new number to a name that held a game variable it was handed: a method's
        # or a block's argument, or a local taken from a Hash or a call. A name holds a value, as in
        # Ruby, so the line moves the name and the variable stays as it was.
        #
        # A warning and not an error: the game does what Ruby says it does, and a name that moves
        # on is sometimes what was meant. It reports from data rather than from the tree, since the
        # write leaves no node behind. See Builder#record_handed_name_write.
        class HandedNameWritten
          NAME = :handed_name_written
          PLAIN_NAME = "a line that writes to a name and not to the game variable it holds"

          # @param writes [Array<Builder::HandedNameWrite>] one for each line
          def initialize(writes)
            @writes = writes
          end

          def detect(_program)
            @writes.map { |write| Finding.new(check: NAME, severity: :warning, message: message(write), node: :program) }
          end

          private

          def message(write)
            where = write.source ? " at #{write.source}" : ""
            "`#{write.name}`#{where} holds the game variable :#{write.variable}, and this line gives the name a new " \
              "number. This does not change :#{write.variable}. If the game must see the change, write to where " \
              ":#{write.variable} is kept, or give the number back from the method. If not, use another name."
          end
        end
      end
    end
  end
end
