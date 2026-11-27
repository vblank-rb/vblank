# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a sound driver's habit that a console's build does not make yet:
        #
        # > This game is built for the <console>. Its sound driver has <what>, and the <console>'s build
        # > does not make that yet. To fix this, remove it from the game, or build the game for a console
        # > that makes it.
        #
        # What can be named: `effects_start: :on_next_tick` and `silent_music_stops_ticks: true` on
        # `sound_driver`, and `sent_after_rows:` on a request (Audio::SoundDriver). The interpreter plays them
        # all; a build that does not is refused here, rather than playing the effects on other beats than
        # the interpreter does.
        class SoundDriverNotMadeYet
          NAME = :sound_driver_not_made_yet
          PLAIN_NAME = "a sound driver's habit that the console's build does not make yet"

          # The consoles whose builds make every habit.
          MADE = %i[snes].freeze

          def detect(program)
            console = program.described_console
            return [] if MADE.include?(console.name)

            habits(program).map do |what, node|
              Finding.new(check: NAME, severity: :error, node: node, message: message(what, console))
            end
          end

          private

          # Each habit the program names, with the node that names it first.
          def habits(program)
            found = {}
            program.walk.each do |node|
              if node.kind == :song
                found["`effects_start: :on_next_tick`"] ||= node if node.starts_on_tick
                found["`silent_music_stops_ticks: true`"] ||= node if node.silent_music_stops_ticks
              elsif Tunes::ROW_REQUESTS.include?(node.kind) && node.sent_after_rows
                found["a request with `sent_after_rows:`"] ||= node
              end
            end
            found
          end

          def message(what, console)
            "This game is built for the #{console.title}. Its sound driver has #{what}, and the #{console.title}'s " \
              "build does not make that yet. To fix this, remove it from the game, or build the game for a console " \
              "that makes it."
          end
        end
      end
    end
  end
end
