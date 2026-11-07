# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module VBlank
  module Original
    # A PORT'S RAKE TASK FOR CHECKING ITS SHELL (Live::ShellCheck). In the game's Rakefile:
    #
    #   require "vblank/original/shell_check_tasks"
    #
    #   VBlank::Original::ShellCheckTasks.new do |t|
    #     t.game_file = "game.rb"               # the file `vblank run game.rb --shell` plays
    #     t.console = :gbc                      # every console the game names unless set
    #     t.tape = "test/tapes/first_room.tape" # what is pressed; nothing for 300 passes unless set
    #   end
    #
    # That defines one task:
    #
    #   rake shell:check   build the game as a shell, fill it from the copy this machine names,
    #                      start it again with the copy out of reach, and hold the pack and the
    #                      play to the all-in-one build's
    #
    # The copy is found as the game's build finds it (Original::Game#copy). A machine that names
    # none stops with the words that say how to name one, and the task fails.
    class ShellCheckTasks < Rake::TaskLib
      attr_accessor :game_file, :console, :tape

      def initialize
        super
        @game_file = nil
        @console = nil
        @tape = nil
        yield self if block_given?
        define_tasks
      end

      private

      # Runs the check for +console+, or every console the game names. Raises Live::ShellCheck::Failed,
      # or Original::NotSet when this machine names no copy.
      def run_check
        require_relative "../live"
        game = loaded_game
        Live::ShellCheck.new(game, consoles: console ? [console] : game.consoles, tape: tape && Playthroughs::Tape.read(tape)).run
      end

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
        end
      end
    end
  end
end
