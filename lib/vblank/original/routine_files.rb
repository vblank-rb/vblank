# frozen_string_literal: true

require "digest"
require "rbconfig"
require "tmpdir"

module VBlank
  module Original
    # THE FILES A PORT'S UNPACKING ROUTINE WAS BUILT FROM, each by its full path and the digest of
    # its contents as they were (nil for a file that was not there). Recorded as the routine is
    # built (RoutineBuild), so a later build can tell whether building it again would build the
    # same program without building it: it hashes the same files again (#unchanged?).
    #
    # Three kinds of file are recorded:
    #
    # - every file read while the routine was built (FilesRead): the port's data, a layout or a
    #   table it reads as it goes;
    # - every file read in the process before (FilesRead.read_in_process), since a game file may
    #   read its data as it loads, or a manifest once, long before the routine is built. Taking
    #   every one costs a needless build where an unrelated file changed, never a stale pack. A
    #   file in the machine's folder for temporary files is not taken from these: what is there is
    #   a build's own scratch, made again each time. The routine's own reads are taken wherever
    #   they are;
    # - every Ruby file that defines a method or a constant of a module this process can reach, and
    #   the files the routine's blocks are written in. The port's Ruby is loaded before the routine
    #   is built, so no read of it can be seen then, and Ruby cannot say which constants the
    #   routine's code read (PackLibrary says more), so every file of the game's own code is taken.
    #   A change to any of them builds the routine again; a pack whose program comes out the same
    #   still hits (PackCache#pack_of_routine).
    #
    # Neither list holds a file of the libraries the game runs on: VBlank's own lib, which the pack
    # cache's key digests already (PackLibrary), Ruby's, and the installed gems'. Their folders are
    # worked out once, as this file loads, since a Ractor may not read where Ruby keeps them.
    class RoutineFiles
      # VBlank's own lib, ending in "/".
      VBLANK_FOLDER = Ractor.make_shareable(File.join(VBlank.root.join("lib").to_s, ""))

      # The folders each name and its real path, ending in "/".
      def self.folders_named(folders)
        folders.compact.flat_map do |folder|
          named = File.expand_path(folder.to_s)
          [named, (File.realpath(named) if File.directory?(named))].compact.map { |each| File.join(each, "") }
        end
      end

      # Where Bundler installs gems, or nil where Bundler is not loaded or has no Gemfile.
      def self.bundle_folder
        Bundler.bundle_path if defined?(Bundler)
      rescue StandardError
        nil
      end

      # The folders whose files are no game's, each ending in "/": VBlank's lib, Ruby's library
      # folders and the folders gems are installed in, each exactly, so a game kept beside them
      # (under /usr/src, say) is still the game's.
      LIBRARY_FOLDERS = Ractor.make_shareable(
        [VBLANK_FOLDER, *folders_named([*RbConfig::CONFIG.values_at("rubylibdir", "rubyarchdir", "sitelibdir", "sitearchdir",
                                                                     "vendorlibdir", "vendorarchdir"),
                                        *(Gem.path if defined?(Gem)), bundle_folder])].uniq
      )

      # The machine's folder for temporary files, as named and as its real path, ending in "/".
      TEMPORARY_FOLDERS = Ractor.make_shareable(folders_named([Dir.tmpdir]).uniq)

      # The files given, each hashed now. +read+ are the full paths read while the routine was
      # built (FilesRead), +blocks+ the routine's blocks (Procs), whose files are taken too, and
      # every file read in the process before.
      def self.recorded(read:, blocks:)
        written_in = blocks.filter_map { |block| block.source_location&.first }
        before = FilesRead.read_in_process.reject { |path| TEMPORARY_FOLDERS.any? { |folder| path.start_with?(folder) } }
        paths = (read + before + written_in + ruby_files).uniq.select { |path| game_file?(path) }.sort
        new(paths.to_h { |path| [path, digest_of(path)] })
      end

      # Whether +path+ is a file of the game's own: a full path outside every library folder.
      def self.game_file?(path) = path.start_with?("/") && LIBRARY_FOLDERS.none? { |folder| path.start_with?(folder) }

      # The digest of the file at +path+ as it is now, or nil where there is no such file.
      def self.digest_of(path) = File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil

      # EVERY RUBY FILE THAT DEFINES SOMETHING THIS PROCESS CAN REACH: a method of a module, or a
      # constant, found from Object down through every constant that is a module. It is read from
      # the modules rather than from $LOADED_FEATURES, which a Ractor may not read, and it finds a
      # file loaded by `load` too. A constant a Ractor may not read is a value, never a module (a
      # module can always be shared), so passing over one loses nothing.
      def self.ruby_files
        files = {}
        seen = {}.compare_by_identity
        waiting = [Object]
        until waiting.empty?
          mod = waiting.pop
          next if seen.key?(mod)

          seen[mod] = true
          note_method_files(mod, files)
          note_method_files(mod.singleton_class, files)
          note_constant_files(mod, files, waiting)
        end
        files.keys
      end

      # The files +owner+'s own methods are written in, noted in +files+.
      def self.note_method_files(owner, files)
        (owner.instance_methods(false) + owner.private_instance_methods(false)).each do |name|
          location = owner.instance_method(name).source_location
          files[location.first] = true if location
        rescue StandardError
          # Must pass over a method that cannot be looked at here: one defined by a block in another
          # Ractor raises as it is asked for, and its file is found through its module's constant.
          next
        end
      rescue StandardError
        # A module whose list of methods cannot be read here (one that redefines how it is listed).
        nil
      end
      private_class_method :note_method_files

      # The files +mod+'s own constants are set in, noted in +files+, and each constant that is a
      # module put in +waiting+. A constant still to be autoloaded is not loaded for this, and one
      # set by Ruby or a gem is not looked into: no game's code is inside it, and reading some of
      # them prints that they are deprecated.
      def self.note_constant_files(mod, files, waiting)
        mod.constants(false).each do |name|
          file = mod.const_source_location(name)&.first
          next unless file

          files[file] = true
          next if mod.autoload?(name, false) || !(game_file?(file) || file.start_with?(VBLANK_FOLDER))

          value = mod.const_get(name, false)
          waiting << value if value.is_a?(Module)
        rescue StandardError, Ractor::IsolationError
          # Must pass over a constant this Ractor may not read, or one that is gone: neither is a module.
          next
        end
      end
      private_class_method :note_constant_files

      # +digests+ is each file's digest by its full path, nil for a file that was not there.
      def initialize(digests)
        @digests = digests.freeze
      end

      attr_reader :digests

      # Whether every file hashes as it did when recorded, and is still there or still not.
      def unchanged? = @digests.all? { |path, digest| RoutineFiles.digest_of(path) == digest }
    end
  end
end
