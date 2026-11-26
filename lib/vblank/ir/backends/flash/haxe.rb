# frozen_string_literal: true

require "open3"

module VBlank
  module IR
    module Backends
      class Flash
        # The Haxe compiler, which turns the printed game and the runtime into one .swf, as zig does
        # for the C build. It is found on the PATH, or through HAXE_PATH, which names the compiler or
        # the folder it is in (its std/ folder is then taken to be beside it, unless HAXE_STD_PATH says
        # where it is).
        module Haxe
          # The Flash version the movie is made for. 10.1 is what the Flex SDK's player library
          # reaches, and what the runtime needs (Vector, SampleDataEvent, SharedObject).
          SWF_VERSION = "10.1"

          # Raised when Haxe is missing or refuses the program.
          class Error < StandardError; end

          module_function

          # The compiler to run, and what to add to its environment, or an Error saying how to install it.
          def compiler
            named = ENV["HAXE_PATH"]
            if named && !named.empty?
              path = File.directory?(named) ? File.join(named, "haxe") : named
              std = File.join(File.dirname(path), "std")
              return [path, File.directory?(std) ? { "HAXE_STD_PATH" => std } : {}] if File.file?(path)
            end
            found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |folder| File.join(folder, "haxe") }.find { |path| File.file?(path) }
            return [found, {}] if found

            raise Error, "Haxe was not found. Install Haxe 4.3 (https://haxe.org/download/, or unpack its release and " \
                         "put its folder on the PATH), or set HAXE_PATH to the compiler or to its folder."
          end

          # Compiles the Haxe in +source_dir+ (its main class is +main+) into the movie at +swf+, which is
          # +width+ by +height+ and asks to be woken +frame_rate+ times a second. Gives back +swf+.
          def compile(source_dir, main:, swf:, width:, height:, frame_rate: 60, defines: [])
            path, environment = compiler
            header = "#{width}:#{height}:#{frame_rate}:000000"
            arguments = ["-cp", source_dir, "--swf", swf, "--swf-version", SWF_VERSION, "-D", "swf-header=#{header}",
                         "-D", "no-traces=0", *defines.flat_map { |define| ["-D", define] }, "-main", main]
            out, status = Open3.capture2e(environment, path, *arguments)
            raise Error, "Haxe refused the game:\n#{out}" unless status.success?

            swf
          end
        end
      end
    end
  end
end
