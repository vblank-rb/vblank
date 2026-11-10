# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyDOSEmulator
  # A COPY OF THE CORE FOR ONE MACHINE, never used for a second. A libretro core keeps its whole machine
  # in the library's own globals, so two machines in one process need two libraries (the system loads
  # one file once, whatever its name is not). And a machine cannot be started again in a library that
  # has run one: DOSBox Pure keeps a thread and C++ statics that closing the library does not undo
  # (it stays mapped), so the next machine in the same file starts from the last one's ruins and stops
  # with a segmentation fault. So each machine gets a file of its own, made here and deleted as soon as
  # the library is loaded (the system keeps the loaded file alive).
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
