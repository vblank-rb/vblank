# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a request sent at a screen row past the frame:
        #
        # > A request has `sent_after_rows: 300`. A frame of the Super Nintendo has 262 rows. The request
        # > is sent in the pass that asks for it, so its row must be in that frame. To fix this, use a row
        # > less than 262.
        #
        # A row is counted from the start of the vertical blank, in the pass that asks (Audio::SoundDriver),
        # and that pass ends where the frame does. Held to the frame, a pass's requests reach at most one
        # wake past the frame's last, so a driver keeps a few of them at once.
        class RowPastFrame
          NAME = :row_past_frame
          PLAIN_NAME = "a request at a row past the frame"

          def detect(program)
            console = program.described_console
            return [] unless console.cycles_a_line

            rows = (console.cycles_a_frame.to_r / console.cycles_a_line).ceil
            program.walk.filter_map do |node|
              next unless Tunes::ROW_REQUESTS.include?(node.kind) && node.sent_after_rows
              next if node.sent_after_rows * console.cycles_a_line < console.cycles_a_frame

              Finding.new(check: NAME, severity: :error, node: node, message: message(node.sent_after_rows, console, rows))
            end
          end

          private

          def message(given, console, rows)
            "A request has `sent_after_rows: #{given.to_i == given ? given.to_i : given.to_f}`. A frame of the " \
              "#{console.title} has #{rows} rows. The request is sent in the pass that asks for it, so its row must " \
              "be in that frame. To fix this, use a row less than #{rows}."
          end
        end
      end
    end
  end
end
