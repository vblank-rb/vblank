# frozen_string_literal: true

module VBlank
  module Original
    # THE FILES THIS PROCESS READ, by their full paths. A port's unpacking routine is game code, and
    # the Ruby that builds it may depend on files of the port's own: a layout written as JSON, read
    # as the routine is built, or a table of levels a game file reads as it loads
    # (`LEVELS = JSON.parse(File.read("levels.json"))`), or a manifest read once and kept. What the
    # routine is built from is then those files too, so the pack cache must know them to tell
    # whether a routine it built before is the one this build would build (RoutineFiles,
    # PackCache#pack_of_routine).
    #
    # So every file read in the process is noted, from the moment the library loads:
    #
    #   FilesRead.read_in_process          # every file read so far, as full paths
    #   paths, routine = FilesRead.recording { build_the_routine }   # and those read in the block
    #
    # Ruby has no one place every read goes through, so the ways a file is read by name are wrapped
    # for the whole process as this file loads: IO.read, IO.binread, IO.readlines and IO.foreach
    # (File's are IO's, and Pathname#read and JSON.load_file call File.read), File#initialize,
    # which File.open and File.new go through, and Zlib::GzipReader.open where Zlib is loaded
    # first. A file opened only to write or append to is not noted. A file read some other way (a
    # C extension, Dir.glob listing a folder) is not noted at all.
    #
    # RACTORS. The main Ractor keeps its list as a frozen, shareable copy, replaced as each new file
    # is read, which any Ractor may read: a game's files load on the main Ractor. Another Ractor
    # keeps what it reads in a list of its own beside that. What one worker Ractor reads, another
    # does not see.
    module FilesRead
      # Where the thread keeps the list of the block recording now, or nil.
      RECORDING = :vblank_files_read
      # Set on the thread while its reads are not to be noted (#unrecorded).
      UNRECORDED = :vblank_files_unrecorded
      # Where a Ractor other than the main one keeps the files it read, by path.
      READ_HERE = :vblank_files_read_here

      @read_on_main = Ractor.make_shareable([])
      @noted_on_main = {}
      @lock = Mutex.new

      # Every file read in this process so far, as full paths: the main Ractor's and this Ractor's.
      def self.read_in_process
        here = Ractor.current[READ_HERE]
        here ? (@read_on_main + here.keys).uniq : @read_on_main
      end

      # The block's value and the full paths of the files it read on this thread, in the order
      # read, as [paths, value]. A recording inside another adds its files to the outer one's too.
      def self.recording
        outer = Thread.current[RECORDING]
        paths = []
        Thread.current[RECORDING] = paths
        begin
          value = yield
        ensure
          Thread.current[RECORDING] = outer
          outer&.concat(paths)
        end
        [paths, value]
      end

      # The block's value, its reads on this thread not noted: for the pack cache reading its own
      # entries, which are no input to any routine.
      def self.unrecorded
        before = Thread.current[UNRECORDED]
        Thread.current[UNRECORDED] = true
        yield
      ensure
        Thread.current[UNRECORDED] = before
      end

      # Notes +name+, a file about to be read. A name that is no path (a file descriptor, a command
      # after "|") is not noted.
      def self.note(name)
        return if Thread.current[UNRECORDED]

        path = name.respond_to?(:to_path) ? name.to_path : name
        return unless path.is_a?(String) && !path.start_with?("|")

        path = File.expand_path(path)
        Thread.current[RECORDING]&.push(path)
        if Ractor.current == Ractor.main
          note_on_main(path)
        else
          (Ractor.current[READ_HERE] ||= {})[path] = true
        end
      end

      def self.note_on_main(path)
        @lock.synchronize do
          next if @noted_on_main.key?(path)

          @noted_on_main[path] = true
          @read_on_main = Ractor.make_shareable([*@read_on_main, path])
        end
      end
      private_class_method :note_on_main

      # Whether +mode+, as File.open is given it (a string, flags, or nil), opens a file only to
      # write or append to it.
      def self.write_only?(mode)
        case mode
        when Integer then (mode & File::ACCMODE) == File::WRONLY
        when String then mode.match?(/[wa]/) && !mode.include?("+")
        else false
        end
      end

      # Wrapped around IO's ways of reading a file by name.
      module NamedReads
        def read(name, *rest, **options)
          FilesRead.note(name)
          super
        end

        def binread(name, *rest)
          FilesRead.note(name)
          super
        end

        def readlines(name, *rest, **options)
          FilesRead.note(name)
          super
        end

        def foreach(name, *rest, **options, &)
          FilesRead.note(name)
          super
        end
      end

      # Wrapped around File#initialize, which File.open and File.new go through.
      module Opening
        def initialize(name, *rest, **options, &)
          FilesRead.note(name) unless FilesRead.write_only?(options.fetch(:mode, options.fetch(:flags, rest.first)))
          super
        end
      end

      # Wrapped around Zlib::GzipReader.open, which opens its file without File#initialize.
      module GzipOpening
        def open(name, *rest, **options, &)
          FilesRead.note(name)
          super
        end
      end

      IO.singleton_class.prepend(NamedReads)
      File.prepend(Opening)
      Zlib::GzipReader.singleton_class.prepend(GzipOpening) if defined?(Zlib::GzipReader)
    end
  end
end
