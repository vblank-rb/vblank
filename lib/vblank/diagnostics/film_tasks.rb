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
    #   end
    #
    # A SIDE is a label (written over its pictures) and its cartridge: a path to a cartridge file,
    # a built cartridge, or a lambda answering either, called only when that film is made. Either
    # side can be any cartridge, so a game with no retail cartridge to set beside it films two
    # builds of its own. A film file can name sides of its own (FilmScript#side).
    #
    # The task loads the library, the game's code and the film only when it runs, so defining it
    # costs a Rakefile nothing, and it starts no test framework. Making a film needs ImageMagick and
    # ffmpeg; nothing else a game does needs either, and a missing one stops the task saying what
    # to install.
    class FilmTasks < Rake::TaskLib
      attr_accessor :name, :films, :out, :libs, :requires, :sides

      def initialize(name = :film)
        super()
        @name = name
        @films = "films"
        @out = ".cache/films"
        @libs = []
        @requires = []
        @sides = {}
        yield self if block_given?
        define_film_task
      end

      # The names of the films there are, from the files in #films.
      def film_names = Dir[File.join(films, "*.rb")].map { |path| File.basename(path, ".rb") }.sort

      # Make the film +film_name+ and answer the MP4's path. +search_path+ is where ImageMagick and
      # ffmpeg are looked for (see Film.make).
      def make_film(film_name, search_path: ENV.fetch("PATH", ""))
        refuse_unknown_film!(film_name)
        load_game
        plan = FilmScript.read(File.join(films, "#{film_name}.rb"), sides: sides)
        plan.make(File.join(out, "#{film_name}.mp4"), search_path: search_path)
      end

      private

      def define_film_task
        desc "Make a film as an MP4 in #{out} (NAME=<a film in #{films}/>)"
        task(name) do
          path = make_film(ENV.fetch("NAME", nil))
          puts "The film is at #{path}."
        rescue Film::MissingTool => e
          abort e.message
        end
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
