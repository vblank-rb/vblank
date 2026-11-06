# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module VBlank
  module Diagnostics
    # A GAME'S RAKE TASK FOR FILMS: `rake film NAME=door` makes the film written in films/door.rb
    # (FilmScript) and writes it as an MP4 a person can watch without running anything. In the
    # game's Rakefile:
    #
    #   require "vblank/diagnostics/film_tasks"
    #
    #   VBlank::Diagnostics::FilmTasks.new do |t|
    #     t.films = "films"                            # where the film files are (the default)
    #     t.out = ".cache/films"                       # where the MP4s go (the default); keep it out of git
    #     t.libs = %w[lib test/support]                # folders a film file can require from by bare name
    #     t.requires = %w[my_game]                     # what every film needs loaded first
    #     t.sides = { "ours" => -> { MyGame.build_rom },          # a built cartridge, or a path to one
    #                 "retail cartridge" => "baserom.gba" }
    #     t.console = :ps1                             # build each game for this console
    #     t.lowering = "ruby"                          # show each side this way (the emulator if unsaid)
    #   end
    #
    # A SIDE is a label (written over its pictures) and its cartridge: a path to a cartridge file,
    # a built cartridge, a game to build (MY_GAME, what `VBlank.game` hands back), or a lambda
    # answering any of them, called only when that film is made. Either side can be any cartridge,
    # so a game with no retail cartridge to set beside it films two builds of its own. A film file
    # can name sides of its own (FilmScript#side).
    #
    # CONSOLE AND LOWERING. `rake film NAME=door CONSOLE=ps1 LOWERING=ruby` sets them for one film,
    # over what the Rakefile sets (an empty one sets nothing); a side the film file names with its own
    # keeps its own. The console is the one a game to build is built for (the first the game names
    # unless set); a built cartridge or a file is for one console already, and a side that names
    # another is refused. The lowering is how the game is shown: the cartridge in its console's
    # emulator unless set, or ruby, js, native or interpreter
    # (Playthroughs::CommandLine::SHOWN_WAYS), which play the game itself, so a cartridge file is
    # shown only in the emulator.
    #
    # The task loads the library, the game's code and the film only when it runs, so defining it
    # costs a Rakefile nothing, and it starts no test framework. Making a film needs ImageMagick and
    # ffmpeg; nothing else a game does needs either, and a missing one stops the task saying what
    # to install.
    class FilmTasks < Rake::TaskLib
      attr_accessor :name, :films, :out, :libs, :requires, :sides, :console, :lowering

      def initialize(name = :film)
        super()
        @name = name
        @films = "films"
        @out = ".cache/films"
        @libs = []
        @requires = []
        @sides = {}
        @console = nil
        @lowering = nil
        yield self if block_given?
        define_film_task
      end

      # The names of the films there are, from the files in #films.
      def film_names = Dir[File.join(films, "*.rb")].map { |path| File.basename(path, ".rb") }.sort

      # Make the film +film_name+ and answer the MP4's path. +search_path+ is where ImageMagick and
      # ffmpeg are looked for (see Film.make). +console+ and +lowering+ are what each side is opened
      # with unless it sets its own: the Rakefile's unless set.
      def make_film(film_name, search_path: ENV.fetch("PATH", ""), console: self.console, lowering: self.lowering)
        refuse_unknown_film!(film_name)
        load_game
        plan = FilmScript.read(File.join(films, "#{film_name}.rb"), sides: sides, console: console, lowering: lowering)
        plan.make(File.join(out, "#{film_name}.mp4"), search_path: search_path)
      end

      private

      def define_film_task
        desc "Make a film as an MP4 in #{out} (NAME=<a film in #{films}/>; CONSOLE=<gba, gbc, snes, genesis or " \
             "ps1> builds the game for that console; LOWERING=<emulator, ruby, js, native or interpreter> shows it " \
             "that way, the cartridge in its emulator if unsaid)"
        task(name) do
          path = make_film(ENV.fetch("NAME", nil), console: setting_from_environment("CONSOLE") || console,
                                                   lowering: setting_from_environment("LOWERING") || lowering)
          puts "The film is at #{path}."
        rescue Film::MissingTool => e
          abort e.message
        end
      end

      # What the command line gives for +key+, or nil where it gives nothing: `CONSOLE=` empty is unset,
      # and leaves the Rakefile's.
      def setting_from_environment(key)
        value = ENV.fetch(key, nil)
        value unless value.nil? || value.empty?
      end

      def load_game
        libs.reverse_each { |lib| $LOAD_PATH.unshift(File.expand_path(lib)) unless $LOAD_PATH.include?(File.expand_path(lib)) }
        require_relative "../../vblank"
        requires.each { |path| require path }
      end

      def refuse_unknown_film!(film_name)
        names = film_names
        if names.empty?
          abort "There are no films in #{films}. A film is a .rb file in that folder that says which frames to show: " \
                "`parts 1..90`."
        end
        listed = "The films in #{films} are: #{names.join(', ')}."
        abort "Say which film to make: `rake #{name} NAME=#{names.first}`. #{listed}" if film_name.to_s.empty?
        abort "There is no film called #{film_name}. #{listed}" unless names.include?(film_name)
      end
    end
  end
end
