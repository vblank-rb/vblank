# frozen_string_literal: true

require "json"
require "rbconfig"

module VBlank
  module Live
    # THE HIDDEN PROCESS THAT BUILDS A GAME FOR A WINDOW THAT WAITS (BuildWatch). vblank run starts
    # it (BuildHelper.start), and it builds the game, writes it out as one Ruby file
    # (IR::Backends::Ruby#build_script), says where, and ends: everything the build made goes with
    # it, and the window plays the written game with none of it.
    #
    # As it builds it says what it is doing in the lines BuildWatch reads, on a pipe of its own (its
    # descriptor PIPE_FD), so whatever a game file prints, and the build's warnings, still go to the
    # terminal as they always have.
    module BuildHelper
      # The descriptor the helper says what it is doing on.
      PIPE_FD = 3

      # Where the helper's process starts: this file's main, with the library on its load path.
      STARTER = "require 'vblank/live'; VBlank::Live::BuildHelper.main(ARGV)"

      # A helper building the game in +game_file+ for +console+ (a Symbol), told +settings+ (--set's,
      # names to text), keeping it in +slot+ (a WrittenGames::Slot) under +library+ (the command's
      # WrittenGames::LibraryKey, worked out once for the launch). +match+ writes in what a match needs
      # to know of the game (Ruby#build_script). Gives back its pid and the end of
      # the pipe it says what it is doing on, which BuildWatch reads.
      def self.start(game_file:, console:, settings:, slot:, library:, match: false)
        reader, writer = IO.pipe
        pid = Process.spawn(RbConfig.ruby, "-I", VBlank.root.join("lib").to_s, "-e", STARTER, "--",
                            File.expand_path(game_file), console.to_s, slot.folder, JSON.generate(settings),
                            JSON.generate(library.to_plain), match.to_s, PIPE_FD => writer, in: File::NULL)
        writer.close
        [pid, reader]
      end

      # The helper's work, in its own process: the game built, written and kept with what the build
      # read (WrittenGames, BuildInputs), and the window told where, or told in plain words why it
      # cannot play. Ends the process.
      #
      # A window that has gone (closed, or killed) leaves the pipe with no reader, and Ctrl-C at the
      # terminal reaches this process too: either ends it quietly, with nothing more to say.
      def self.main(arguments)
        game_file, console, folder, settings, library, match = arguments
        match = match == "true"
        settings = JSON.parse(settings).transform_keys(&:to_sym)
        library = WrittenGames::LibraryKey.new(**JSON.parse(library).transform_keys(&:to_sym))
        slot = WrittenGames::Slot.new(folder)
        said = IO.for_fd(PIPE_FD)
        said.sync = true
        # Must not pass to anything the build starts: a process that kept the pipe open would leave
        # the window believing the build goes on.
        said.close_on_exec = true
        sender = Sender.new(said)
        title = File.basename(game_file)
        begin
          slot.prepare
          inputs = BuildInputs.recording do
            # The command loaded this file already, for the title and console it opens the window
            # with; loading it again here is cheap (VBlank.game only records the game) and keeps
            # nothing of the command's in this process. Loaded inside the recording, as is all the
            # game reads while it is built.
            BuildInputs.under_way.note_path(game_file)
            game = load_game(game_file)
            title = game.title
            IR::Backends::Ruby.new.build_script(game, slot.writing_path, console: console.to_sym, progress: sender, match: match,
                                                                         settings: settings)
          end
          slot.keep(inputs, console: console, settings: settings, library: library, match: match)
          sender.say("written", slot.script_path)
          exit 0
        rescue IR::Backends::Ruby::RuntimeGap => e
          sender.say("refused", runtime_gap_message(title, e.part))
        rescue BuildError, ArgumentError => e
          sender.say("refused", refusal_message(title, e))
        end
        exit 1
      rescue Errno::EPIPE, Interrupt
        exit 1 # the window is gone: no backtrace
      end

      # The game +game_file+ declares, as vblank run loads it (the file only records it).
      def self.load_game(game_file)
        VBlank.forget_registered_games!
        load game_file
        VBlank.registered_games.last or raise ArgumentError, "#{File.basename(game_file)} does not declare a game."
      end

      # The words vblank run says for a game the Ruby runtime cannot play yet.
      def self.runtime_gap_message(title, part)
        "VBlank cannot play #{title} in a window yet. The game needs a part of VBlank that does not work in Ruby yet: " \
          "#{part}. Build a cartridge, or use vblank preview."
      end

      # The words vblank run says for a build that stopped: its first line says nothing was made
      # (Messages::BuildStopped), except where the guardrails said that already, above their findings.
      def self.refusal_message(title, error)
        return error.message if !error.is_a?(BuildError) || error.is_a?(StoppedByChecks)

        Messages::BuildStopped.with_headline(error.message, title)
      end

      # A BUILD'S PROGRESS, SAID TO THE WINDOW: each phase and where it has got to, as lines
      # BuildWatch reads. A tick is counted, and its label asked for only a few times a second.
      class Sender < Messages::Progress
        TICK_SECONDS = 0.1 # How often a phase with no count says it is still going

        def initialize(io)
          super()
          @io = io
          @said_at = 0
        end

        # One line of what the helper says: +kind+ and +value+ (BuildWatch lists them).
        def say(kind, value) = @io.write(BuildWatch.message_line(kind, value))

        def step(name) = say("step", name)

        def report_count(done, total, name = nil)
          name ? say("detail", "#{done}/#{total}  #{name}") : say("count", [done, total])
          nil
        end

        def tick
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if now - @said_at < TICK_SECONDS

          @said_at = now
          say("detail", yield.to_s) if block_given?
          nil
        end

        def show_detail(text) = say("detail", text.to_s)

        def as_one_line(name)
          step(name)
          Messages::Progress::Folded.new(self)
        end
      end
    end
  end
end
