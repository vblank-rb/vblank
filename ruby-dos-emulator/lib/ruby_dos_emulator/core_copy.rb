# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

module RubyDOSEmulator
  # A COPY OF THE CORE FOR ONE MACHINE, never used for a second. A libretro core keeps its whole machine
  # in the library's own globals, so two machines in one process need two libraries (the system loads
  # one file once, whatever its name is not). So each machine gets a file of its own, made here and deleted
  # as soon as the library is loaded (the system keeps the loaded file alive).
  #
  # The library is also unloaded when its machine is destroyed, and its static memory goes with it. That
  # needs the core to export nothing but libretro's functions and the probe's, which the probe patch sees
  # to (CoreBuild says why).
  #
  # Each copy's name is made up at random rather than counted: a machine may be made in any Ractor, and
  # only the main one may change a count the class keeps.
  class CoreCopy
    class << self
      # A new copy of +library+ in +folder+.
      def make(library = CoreLibrary.path, folder: Dir.tmpdir)
        FileUtils.mkdir_p(folder)
        path = File.join(folder, "ruby-dos-emulator-core-#{Process.pid}-#{SecureRandom.hex(8)}.so")
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
