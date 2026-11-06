# frozen_string_literal: true

require "rake"
require "rake/tasklib"

module VBlank
  module Diagnostics
    # A GAME'S RAKE TASK FOR PROFILES: `rake profile TAPE=roulette FRAMES=590..610` plays the tape in
    # tapes/roulette.tape on the game's cartridge from power-on and reports each of those frames by
    # itself (TapeProfile): its lines to spare, how much of it the game was awake, and its busiest
    # routines. Without TAPE= it is the profile standing still (`rom.profile`), over FRAMES= frames.
    # In the game's Rakefile:
    #
    #   require "vblank/diagnostics/profile_tasks"
    #
    #   VBlank::Diagnostics::ProfileTasks.new do |t|
    #     t.tapes = "tapes"                                     # where TAPE= finds <name>.tape (the default)
    #     t.libs = %w[lib]                                      # folders the requires are found in
    #     t.requires = %w[my_game]                              # what building the cartridge needs loaded first
    #     t.cartridge = -> { MyGame.game.build_rom(console: :gbc) }
    #   end
    #
    # THE CARTRIDGE is a built one, or a lambda answering one, called only when the task runs. It
    # has to be one the library built, since the profile names routines from the record the build
    # keeps. FORMAT=json gives the same as data.
    #
    # The task loads the library and the game only when it runs, so defining it costs a Rakefile
    # nothing, and it starts no test framework. A profile needs the emulator gem.
    class ProfileTasks < Rake::TaskLib
      attr_accessor :name, :tapes, :libs, :requires, :cartridge

      def initialize(name = :profile)
        super()
        @name = name
        @tapes = "tapes"
        @libs = []
        @requires = []
        @cartridge = nil
        yield self if block_given?
        define_profile_task
      end

      # The names of the tapes there are, from the files in #tapes.
      def tape_names = Dir[File.join(tapes, "*.tape")].map { |path| File.basename(path, ".tape") }.sort

      # Profile the cartridge, reported on +out+, and answer what the profile answers. +tape_name+ is
      # a tape in #tapes or a path to one, or nil for the profile standing still; +frames+ is what
      # FRAMES= sets.
      def profile(tape_name: nil, frames: nil, format: :human, out: $stdout)
        load_game
        tape = (Playthroughs::Tape.read(tape_path(tape_name)) if tape_name)
        frames = TapeProfile.frames_from_text(frames) if frames
        measuring = { format: format, out: out, tape: tape }
        measuring[:frames] = frames if frames
        built_cartridge.profile(**measuring)
      end

      private

      def define_profile_task
        desc "Profile the game's cartridge (TAPE=<a tape in #{tapes}/> FRAMES=590..610 FORMAT=json, each optional)"
        task(name) do
          format = { "human" => :human, "json" => :json }.fetch(ENV.fetch("FORMAT", "human")) do
            abort "FORMAT=#{ENV.fetch('FORMAT', nil)} is not a profile format. The formats are: human, json."
          end
          profile(tape_name: ENV.fetch("TAPE", nil), frames: ENV.fetch("FRAMES", nil), format: format)
        rescue ArgumentError => e
          abort e.message
        end
      end

      def load_game
        libs.reverse_each { |lib| $LOAD_PATH.unshift(File.expand_path(lib)) unless $LOAD_PATH.include?(File.expand_path(lib)) }
        require_relative "../../vblank"
        requires.each { |path| require path }
      end

      def built_cartridge
        if cartridge.nil?
          abort "There is no cartridge to profile. Name it in the Rakefile: " \
                "`t.cartridge = -> { MyGame.game.build_rom(console: :gbc) }`."
        end
        cartridge.respond_to?(:call) ? cartridge.call : cartridge
      end

      # A tape named by its file in #tapes, or a path to any tape file.
      def tape_path(tape_name)
        return tape_name if File.file?(tape_name)

        path = File.join(tapes, "#{tape_name}.tape")
        return path if File.file?(path)

        names = tape_names
        listed = names.empty? ? "There are no tapes in #{tapes}." : "The tapes in #{tapes} are: #{names.join(', ')}."
        abort "There is no tape called #{tape_name}. #{listed}"
      end
    end
  end
end
