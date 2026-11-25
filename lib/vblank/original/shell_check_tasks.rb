# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module VBlank
  module Original
    # A port's rake tasks for checking its shell (Live::ShellCheck and WholeGameCheck). In the game's
    # Rakefile:
    #
    #   require "vblank/original/shell_check_tasks"
    #
    #   VBlank::Original::ShellCheckTasks.new do |t|
    #     t.game_file = "game.rb"               # the file `vblank run game.rb --shell` plays
    #     t.console = :gbc                      # every console the game names unless set
    #     t.tape = "test/tapes/first_room.tape" # what is pressed; nothing unless set
    #     t.passes = 900                        # how much of it shell:check plays (Live::ShellCheck::STRETCH_PASSES unless set)
    #     t.whole_game_tape = "test/tapes/whole_game.tape" # what shell:whole_game plays; t.tape unless set
    #   end
    #
    # That defines two tasks:
    #
    #   rake shell:check        build the game as a shell, fill it from the copy this machine names,
    #                           start it again with the copy out of reach, and hold the pack and a
    #                           short stretch of play to the all-in-one build's
    #   rake shell:whole_game   build the shell's game and the all-in-one build as C, and hold every
    #                           picture and sound of the whole tape to the all-in-one build's; run
    #                           when asked, since it plays as long as the tape is
    #
    # The copy is found as the game's build finds it (Original::Game#copy). A machine that names
    # none stops with the words that say how to name one, and the task fails.
    class ShellCheckTasks < Rake::TaskLib
      attr_accessor :game_file, :console, :tape, :passes, :whole_game_tape

      def initialize
        super
        @game_file = nil
        @console = nil
        @tape = nil
        @passes = nil
        @whole_game_tape = nil
        yield self if block_given?
        define_tasks
      end

      private

      # Runs the check for +console+, or every console the game names. Raises Live::ShellCheck::Failed,
      # or Original::NotSet when this machine names no copy.
      def run_check
        require_relative "../live"
        game = loaded_game
        Live::ShellCheck.new(game, consoles: consoles_of(game), tape: tape && Playthroughs::Tape.read(tape),
                                   passes: passes || Live::ShellCheck::STRETCH_PASSES).run
      end

      # Runs the whole-game check on the whole-game tape, or the shell check's. Raises
      # WholeGameCheck::Failed, or NotSet when this machine names no copy.
      def run_whole_game_check
        # A Rakefile loads only this file, so the library comes in as the task runs, as for shell:check.
        require_relative "../live"
        path = whole_game_tape || tape or
          raise ArgumentError, "The whole-game check names no tape. Set t.whole_game_tape in the Rakefile to a tape " \
                               "recorded from power-on."
        game = loaded_game
        WholeGameCheck.new(game, consoles: consoles_of(game), tape: Playthroughs::Tape.read(path)).run
      end

      def consoles_of(game) = console ? [console] : game.consoles

      # The game the file declares (VBlank.game records it without building).
      def loaded_game
        raise ArgumentError, "The shell check names no game. Set t.game_file in the Rakefile." if game_file.nil?

        VBlank.forget_registered_games!
        load File.expand_path(game_file)
        VBlank.registered_games.last or raise ArgumentError, "#{game_file} does not declare a game with VBlank.game."
      end

      def define_tasks
        namespace :shell do
          desc "Check that the game built as a shell plays as its all-in-one build does"
          task(:check) do
            run_check
          rescue Live::ShellCheck::Failed, CopyError, BuildError, ArgumentError => e
            warn("shell:check: #{e.message}")
            exit(1)
          end

          desc "Check that the shell's game plays the whole tape as the all-in-one build does, both built as C"
          task(:whole_game) do
            run_whole_game_check
          rescue WholeGameCheck::Failed, CopyError, BuildError, ArgumentError => e
            warn("shell:whole_game: #{e.message}")
            exit(1)
          end
        end
      end
    end
  end
end
