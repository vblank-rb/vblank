# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class JS
        # ONE PROGRAM, WRITTEN OUT AS JAVASCRIPT. Make one per program and ask for #source.
        #
        # It is the native lowering's own, printed another way. Native::Lowering turns a program
        # into a small tree of statements (Native::C): globals, routines, tables of numbers, and
        # calls into a runtime — never an operator on a number, since every one goes through a
        # function that does what IR::Int32 does. Nothing in that tree is C's alone, so the same
        # tree is printed as JavaScript here (Printer) and played by a runtime written in
        # JavaScript (runtime/), which is the native runtime's C function for function. The
        # STATEMENTS and VALUES tables, the art worked out in Ruby, which kinds it cannot write
        # yet, what it refuses — a console-only step the program can reach, and only that: all of
        # that is the native lowering's, so the two can never disagree about what a program says,
        # only about how a runtime does it — and each runtime is checked against the interpreter
        # on its own.
        #
        # What differs is said here: the build a refusal names. The guardrail that tells an
        # author about a console-only step before a web build is Guardrails::Checks::WebPortability.
        class Lowering < Native::Lowering
          # The program as one JavaScript file's text: the game alone, with no runtime (see
          # JS#factory for a program that runs).
          def source = text_and_data_file.first

          # The text and, with +data+ :separate, the data file its big tables are in (nil with them
          # :inline, in the text). See Printer#data_file.
          def text_and_data_file(data: :inline)
            refuse_unlowered_kinds!
            printer = Printer.new(data: data)
            [printer.print_file(top_level), printer.data_file]
          end

          private

          def build_name = "the browser build"

          # HOW MANY PLAYERS THE BROWSER'S RUNTIME READS. runtime/rg_runtime.js keeps every
          # player's buttons in one 32-bit number, the second player's 16 bits above the first's
          # (IR::Buttons::PLAYER_SHIFT), so it reads two. The C and Ruby runtimes keep a list, one
          # number per connected player, and read as many as any build does.
          MOST_PLAYERS_READ = 2

          # Everything the native lowering refuses, and a game that reads more players than the
          # browser's runtime does.
          def refuse_unlowered_kinds!
            refuse_players_past_runtime!
            super
          end

          # A line that reads a player the runtime does not, or a game that says it takes more, is
          # refused before anything is written.
          def refuse_players_past_runtime!
            most = MOST_PLAYERS_READ
            declared = @program.most_players
            if declared && declared > most
              raise LoweringError, "this game takes up to #{declared} players (`players:`), and #{build_name} reads " \
                                   "#{most} players at most for now. To fix this, set the most players in " \
                                   "`players:` to #{most} for this build. #{other_builds_read_more}"
            end
            player = @reachable.select { |node| %i[held pressed].include?(node.kind) }
                               .map(&:player).select { |each| each.is_a?(Integer) }.max
            return if player.nil? || player <= most

            raise LoweringError, "this game reads player #{player}, and #{build_name} reads #{most} players at most " \
                                 "for now. To fix this, read players 1 to #{most} only. #{other_builds_read_more}"
          end

          def other_builds_read_more
            "You can also build the game for this computer with `vblank build --format=native`, or play it as " \
              "Ruby with `vblank run`. These builds read up to #{Buttons::MOST_PLAYERS} players."
          end
        end
      end
    end
  end
end
