# frozen_string_literal: true

require "json"

module VBlank
  module IR
    module Backends
      class Ruby
        # The game a file written out as one Ruby file plays (Ruby#script), read back. Such a file is
        # the library's window and session copied in, then the game's part: its title, the console
        # it is for, whether it has a menu, its Ruby, and a shell's parts where it is one. Played with
        # `ruby game-ruby.rb`, the file's own main makes one of these from its constants
        # (WrittenGame.of); the window vblank run opens reads one from a file a helper process wrote
        # (WrittenGame.read). Both then play it the same way (rg_script_main.rb's VBlankScript.play).
        #
        # Carried in every script, so it names nothing of the library a script does not carry.
        #
        # +code+ is the game's code (Cartridge::Game#identifying_code), or nil for a game written
        # with none, which keeps no save states. +match+ is what a match over a network needs to know
        # of the game (Ruby#match_facts, as plain values), or nil for a game written with none.
        # +shell+ is a Shell, the parts Live::Shell is made from as text, or nil for a game that is
        # not one.
        WrittenGame = Data.define(:title, :console_title, :menu, :code, :match, :source, :shell) do
          # The game as Ruby, made a game ready to play afresh each time it is asked.
          def live_game = LiveGame.new(source)

          # The folder its window keeps save states and the game's save memory in, the one vblank
          # run's keeps them in (Live::StateSlots.folder_name), or nil for none.
          def state_folder = (Live::StateSlots.folder_name(title: title, code: code) if code)
        end

        class WrittenGame
          # A shell's parts as a script holds them: +facts+, Original::ShellFacts as JSON, and its
          # +menu+, each of its +unpackings+ (nil for one split in pieces) and each piece's program
          # (+worker_programs+) as Ruby (Live::Shell.new takes them as they are).
          Shell = Data.define(:facts, :menu, :unpackings, :worker_programs)

          # The lines the game's part of a script starts and ends at. #read takes only what lies
          # between them, so nothing of the copied library is read twice.
          PART_BEGINS = "  # THE GAME THIS FILE PLAYS, read back by WrittenGame.read\n"
          PART_ENDS = "  # THE END OF THE GAME'S PART\n"

          # The game a script holds in +holder+'s constants (VBlankScript's, written by Ruby#script).
          def self.of(holder)
            facts = holder.const_get(:SHELL_FACTS)
            if facts
              shell = Shell.new(facts: facts, menu: holder.const_get(:SHELL_MENU), unpackings: holder.const_get(:SHELL_UNPACKINGS),
                                worker_programs: holder.const_get(:SHELL_WORKER_PROGRAMS))
            end
            new(title: holder.const_get(:TITLE), console_title: holder.const_get(:CONSOLE_TITLE), menu: holder.const_get(:MENU),
                code: holder.const_get(:GAME_CODE), match: holder.const_get(:MATCH)&.then { |text| JSON.parse(text) },
                source: holder.const_get(:SOURCE), shell: shell)
          end

          # The game in the script at +path+: its part is read into a module of its own and taken from
          # there, as the script's main takes it. ArgumentError for a file that holds no game's part.
          def self.read(path)
            text = File.read(path, encoding: Encoding::UTF_8)
            from = text.index("\n#{PART_BEGINS}")
            upto = from && text.index("\n#{PART_ENDS}", from)
            raise ArgumentError, "#{path} is not a game that VBlank wrote out as Ruby." unless upto

            holder = Module.new
            holder.module_eval(text[(from + 1)...upto], path, text[0..from].count("\n") + 1)
            of(holder)
          end
        end
      end
    end
  end
end
