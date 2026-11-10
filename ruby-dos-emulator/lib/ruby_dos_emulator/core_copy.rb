# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyDOSEmulator
  # A COPY OF THE CORE FOR ONE MACHINE, never used for a second. A libretro core keeps its whole machine
  # in the library's own globals, so two machines in one process need two libraries (the system loads
  # one file once, whatever its name is not). So each machine gets a file of its own, made here and deleted
  # as soon as the library is loaded (the system keeps the loaded file alive).
  #
  # The library is also unloaded when its machine is destroyed, which frees its 42 MB of static memory. That
  # needs the core to export nothing but libretro's functions and the probe's (core/dosbox-exports.map):
  # exporting the C++ standard library's templates as well makes libstdc++ bind to the library's copies, and
  # then the system never unloads it.
  class CoreCopy
    @count = 0

    class << self
      # A new copy of +library+ in +folder+.
      def make(library = CoreLibrary.path, folder: Dir.tmpdir)
        FileUtils.mkdir_p(folder)
        @count += 1
        path = File.join(folder, "ruby-dos-emulator-core-#{Process.pid}-#{@count}.so")
        FileUtils.cp(library, path)
        new(path)
      end
    end

    attr_reader :path

    def initialize(path)
      @path = path
    end

    # Deletes the file. The library loaded from it stays loaded and working.
    def delete = FileUtils.rm_f(@path)
  end
end
