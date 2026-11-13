# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A local set from a button (`held`, `pressed`) while the game sets up, and read by game
        # code: a `func`, a scene or the game loop. A Ruby local keeps the answer of its line, so
        # the local holds the buttons as they were at power-on, and the game never sees a press.
        #
        # A warning and not an error: the game does what Ruby says it does. But a button read
        # once, before anybody can press it, is never what a game means. It reports from data
        # rather than from the tree, since the line leaves only a copy behind. See
        # Builder#record_kept_button.
        class PressKeptFromSettingUp
          NAME = :press_kept_from_setting_up
          PLAIN_NAME = "a button read while the game sets up, and used as it plays"

          # @param kept [Array<Builder::KeptButton>] one for each line
          def initialize(kept)
            @kept = kept
          end

          def detect(_program)
            @kept.map { |line| Finding.new(check: NAME, severity: :warning, message: message(line), node: :program) }
          end

          private

          def message(line)
            name = line.local ? "`#{line.local}`" : "This name"
            where = line.source ? " at #{line.source}" : ""
            "#{name}#{where} gets its value from a button before the game starts to play. The game reads it while " \
              "it plays. It keeps the button as it was at the start, so it does not change. Read the button where " \
              "it is used: put the `pressed` or `held` test in the routine or the loop that reads it."
          end
        end
      end
    end
  end
end
