# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a request sent at a screen row in a game whose sound driver has no wakes:
        #
        # > A request has `sent_after_rows:`, and the game's sound driver has no wakes. A row says where in the
        # > frame the driver picks the request up. To fix this, give `sound_driver` an `interrupts_per_second:`,
        # > or remove `sent_after_rows:`.
        #
        # A row moves a request to the driver's first wake past it (Audio::SoundDriver), so with no wakes it
        # would change nothing, and is refused rather than ignored.
        class RowWithoutWakes
          NAME = :row_without_wakes
          PLAIN_NAME = "a request at a row with no sound driver wakes"

          MESSAGE = "A request has `sent_after_rows:`, and the game's sound driver has no wakes. A row says where in " \
                    "the frame the driver picks the request up. To fix this, give `sound_driver` an " \
                    "`interrupts_per_second:`, or remove `sent_after_rows:`."

          def detect(program)
            row = program.walk.find { |node| Tunes::ROW_REQUESTS.include?(node.kind) && node.sent_after_rows } or return []
            return [] if Tunes.effect_tempo_step(program)

            [Finding.new(check: NAME, severity: :error, node: row, message: MESSAGE)]
          end
        end
      end
    end
  end
end
