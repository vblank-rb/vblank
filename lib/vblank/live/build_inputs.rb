# frozen_string_literal: true

require "digest"
require "json"
require "rbconfig"

module VBlank
  module Live
    # WHAT A BUILD READ, recorded as it read it, so a game written out by an earlier build can be
    # played again only while everything it was built from is as it was (WrittenGames). Nothing is
    # guessed: the build's own reads are watched while it runs (#recording), and each is asked again
    # (#current?).
    #
    # It records three kinds of thing:
    #
    #   a path    a file read (its contents), a file or folder asked about (whether it is there,
    #             its size), or a folder listed (the names in it); kept as the path's state then:
    #             a file's digest, a folder's names, or that nothing is there
    #   a glob    a Dir.glob or Dir[] and what it found
    #   a setting an environment variable read, and its value then; or the whole environment
    #             (ENV.to_h, ENV.each), kept as a digest of every variable
    #
    # The Ruby files the build loaded (require, load) are paths too. A path inside VBlank's own
    # library or Ruby's standard library is left out: the library's key and Ruby's version stand
    # for those (WrittenGames).
    #
    # HOW THE READS ARE SEEN: the methods Ruby reads files, folders and the environment with are
    # wrapped (PATH_METHODS and the modules after it), each noting what it was asked and then doing
    # what it always does. Only the main Ractor records; a build runs on it.
    #
    # A READ MADE OUTSIDE RUBY IS SEEN ONLY THROUGH .note_read. A child process (ImageMagick decoding
    # a picture) or C code opening a file itself reads past every wrapped method, so the library
    # calls BuildInputs.note_read(path) wherever it hands a file to one (Graphics::Image::Adapters::
    # ImageMagick). A new place that does must call it too, or an edit to that file plays the old game.
    class BuildInputs
      # A glob as the build made it, and the paths it found.
      Glob = Data.define(:patterns, :flags, :base, :found)

      # The methods that take the path they read first, wrapped while recording, by the object they
      # are called on. Dir's globs (GlobNoting), the environment's reads (SettingNoting) and a file
      # opened for reading (FileOpenNoting) are wrapped too.
      PATH_METHODS = {
        IO => %i[read binread readlines foreach],
        File => %i[exist? file? directory? size size? zero? empty? mtime stat lstat ftype readable? symlink?],
        Dir => %i[children entries each_child foreach exist? empty?]
      }.freeze

      class << self
        # The recording under way, or nil: read only on the main Ractor.
        attr_reader :under_way

        # A BuildInputs of what the block read as it ran.
        def recording
          recorder = new
          wrap_read_methods
          loaded = $LOADED_FEATURES.dup
          @under_way = recorder
          yield
          ($LOADED_FEATURES - loaded).each { |path| recorder.note_path(path) }
          recorder
        ensure
          @under_way = nil
        end

        # The recording under way when this is the main Ractor, else nil.
        def recorder_here = (under_way if Ractor.current.equal?(Ractor.main))

        # The file at +path+ is read by something no wrapped method sees (a child process, C code):
        # recorded as a read, when a recording is under way. Does nothing otherwise.
        def note_read(path) = recorder_here&.note_path(path)

        # A BuildInputs as #to_plain wrote it.
        def from_plain(plain)
          new(paths: plain.fetch("paths"), settings: plain.fetch("settings"),
              globs: plain.fetch("globs").map { |glob| Glob.new(**glob.transform_keys(&:to_sym)) })
        end

        private

        # The read methods wrapped, once for the process. A wrapped method does nothing new while no
        # recording is under way.
        def wrap_read_methods
          return if @wrapped

          @wrapped = true
          PATH_METHODS.each { |owner, names| owner.singleton_class.prepend(path_noting(names)) }
          Dir.singleton_class.prepend(GlobNoting)
          ENV.singleton_class.prepend(SettingNoting)
          ENV.singleton_class.prepend(EnvironmentNoting)
          File.prepend(FileOpenNoting)
          Dir.prepend(FolderOpenNoting)
          Kernel.prepend(LoadNoting)
          Prism.singleton_class.prepend(path_noting(%i[parse_file])) if defined?(Prism)
        end
      end

      def initialize(paths: {}, globs: [], settings: {})
        @paths = paths
        @globs = globs
        @settings = settings
        @busy = false
        @left_out = [VBlank.root.join("lib").to_s, RbConfig::CONFIG["rubylibdir"]].compact.map { |root| File.join(root, "") }
      end

      # The paths read, each to its state then; the globs made; the settings read, each to its value.
      attr_reader :paths, :globs, :settings

      # Whether everything the build read is as it was: each path in the same state, each glob
      # finding the same, each setting the same value.
      def current?
        @busy = true
        begin
          environment = ENV.to_h
          @paths.all? { |path, state| path_state(path) == state } &&
            @globs.all? { |glob| glob_found(glob) == glob.found } &&
            @settings.all? { |name, value| (name == WHOLE_ENVIRONMENT ? environment_digest(environment) : environment[name]) == value }
        ensure
          @busy = false
        end
      end

      def to_plain = { "paths" => @paths, "globs" => @globs.map { |glob| glob.to_h.transform_keys(&:to_s) }, "settings" => @settings }

      # --- noting, as the wrapped methods do ---

      def note_path(path)
        return if @busy
        return unless path.is_a?(String) || path.respond_to?(:to_path)

        full = File.expand_path(path.to_s)
        return if @paths.key?(full) || @left_out.any? { |root| full.start_with?(root) }

        @busy = true
        begin
          @paths[full] = path_state(full)
        ensure
          @busy = false
        end
      end

      def note_glob(patterns, flags, base, found)
        return if @busy

        @globs << Glob.new(patterns: Array(patterns).map(&:to_s), flags: flags, base: File.expand_path(base || Dir.pwd),
                           found: found.sort)
      end

      def note_setting(name)
        return if @busy || @settings.key?(name.to_s)

        @busy = true
        begin
          @settings[name.to_s] = ENV.to_h[name.to_s]
        ensure
          @busy = false
        end
      end

      def note_whole_environment
        return if @busy || @settings.key?(WHOLE_ENVIRONMENT)

        @busy = true
        begin
          @settings[WHOLE_ENVIRONMENT] = environment_digest(ENV.to_h)
        ensure
          @busy = false
        end
      end

      # The name the whole environment is kept under among the settings: no variable's name can be
      # empty.
      WHOLE_ENVIRONMENT = ""

      private

      def environment_digest(environment) = Digest::SHA256.hexdigest(JSON.generate(environment.sort))

      # A file's digest, a folder's names, or "none".
      def path_state(path)
        if File.file?(path) then "file #{Digest::SHA256.file(path).hexdigest}"
        elsif File.directory?(path) then "folder #{Digest::SHA256.hexdigest(Dir.children(path).sort.join("\0"))}"
        else "none"
        end
      end

      def glob_found(glob) = Dir.glob(glob.patterns, glob.flags, base: glob.base).sort

      # THE WRAPPERS are written as plain methods (module_eval of their text, never define_method
      # with a block): a method made from a block can be called only from the Ractor that made it,
      # and every Ractor in the process reads files through these.
      #
      # A module whose methods take the path they read first, one for each of +names+.
      def self.path_noting(names)
        Module.new.tap do |wrapper|
          names.each do |name|
            wrapper.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{name}(path, *, **, &)
                ::VBlank::Live::BuildInputs.recorder_here&.note_path(path)
                super
              end
            RUBY
          end
        end
      end

      # Wraps Dir.glob and Dir[]: what was found is noted, and handed to a block where one was given.
      module GlobNoting
        def glob(patterns, flags = 0, base: nil, **options, &block)
          flags = options.delete(:flags) || flags # given by name or in its place, it is one setting
          found = super(patterns, flags, base: base, **options)
          ::VBlank::Live::BuildInputs.recorder_here&.note_glob(patterns, flags, base, found)
          return found unless block

          found.each(&block)
          nil
        end

        def [](*patterns, base: nil, **options)
          found = super
          ::VBlank::Live::BuildInputs.recorder_here&.note_glob(patterns, 0, base, found)
          found
        end
      end

      # Wraps the environment's reads.
      module SettingNoting
        %i[[] fetch key? include? has_key? member?].each do |name|
          module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def #{name}(key, *, &)
              ::VBlank::Live::BuildInputs.recorder_here&.note_setting(key)
              super
            end
          RUBY
        end
      end

      # Wraps the environment's reads of every variable at once, and of several named ones.
      module EnvironmentNoting
        %i[to_h to_hash to_a each each_pair each_key each_value keys values select filter reject].each do |name|
          module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def #{name}(*, &)
              ::VBlank::Live::BuildInputs.recorder_here&.note_whole_environment
              super
            end
          RUBY
        end

        def values_at(*names)
          names.each { |name| ::VBlank::Live::BuildInputs.recorder_here&.note_setting(name) }
          super
        end

        def slice(*names)
          names.each { |name| ::VBlank::Live::BuildInputs.recorder_here&.note_setting(name) }
          super
        end
      end

      # Notes a folder opened (Dir.new, Dir.open), which is then listed.
      module FolderOpenNoting
        def initialize(path, *, **)
          ::VBlank::Live::BuildInputs.recorder_here&.note_path(path)
          super
        end
      end

      # Notes a Ruby file loaded with Kernel#load, which $LOADED_FEATURES does not list.
      module LoadNoting
        private

        def load(path, *)
          ::VBlank::Live::BuildInputs.recorder_here&.note_path(path)
          super
        end
      end

      # Notes a file opened for reading (File.open, File.new, Kernel#open of a path).
      module FileOpenNoting
        def initialize(path, *rest, **options, &block)
          BuildInputs.recorder_here&.note_path(path) if FileOpenNoting.reading?(rest.first || options[:mode] || "r")
          super
        end

        # Whether a file opened with +mode+ (text such as "rb", or File's flags) is only read.
        def self.reading?(mode)
          return mode.start_with?("r") && !mode.include?("+") if mode.is_a?(String)

          mode.is_a?(Integer) && (mode & (File::WRONLY | File::RDWR)).zero?
        end
      end
    end
  end
end
