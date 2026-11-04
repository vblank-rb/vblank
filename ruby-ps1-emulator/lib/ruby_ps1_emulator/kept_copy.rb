# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyPS1Emulator
  # A COPY OF THE CORE KEPT ON DISK TO BE OPENED AGAIN. Each console needs a library of its own
  # (see Core), and the machine takes about a second over the first time it opens a file, which a
  # later open of that same file does not cost, from any process. So copies are kept in a folder
  # named for the build they came from, and handed out one console at a time: opening a kept copy
  # is what makes a test's cartridge quick to start.
  #
  # A copy in use is locked, by a lock the system lets go of however its process ends, so
  # consoles in one process and in several each find one nobody has. Nothing sweeps the folder: it
  # is in the system's temporary folder, and a new build of the core gets a folder of its own.
  class KeptCopy
    attr_reader :path

    # A copy nobody is using, locked, made if there is none.
    def self.take(library = CoreLibrary.path, folder: folder_for(library))
      FileUtils.mkdir_p(folder)
      (0..).each do |number|
        path = File.join(folder, "core-#{number}.so")
        lock = File.open("#{path}.lock", File::RDWR | File::CREAT)
        if lock.flock(File::LOCK_EX | File::LOCK_NB)
          make(library, path)
          return new(path, lock)
        end
        lock.close
      end
    end

    # The copies of one build go together: its size and the moment it was built tell it apart.
    def self.folder_for(library)
      stat = File.stat(library)
      File.join(Dir.tmpdir, "ruby-ps1-emulator-#{stat.size}-#{stat.mtime.to_i}")
    end

    # Made under another name and moved into place, so a process ended half way leaves no part of one.
    def self.make(library, path)
      return if File.file?(path)

      FileUtils.cp(library, "#{path}.new")
      File.rename("#{path}.new", path)
    end
    private_class_method :make

    def initialize(path, lock)
      @path = path
      @lock = lock
    end

    def give_back = @lock.close
  end
end
