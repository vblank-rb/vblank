# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Testing
    # BUILT CARTRIDGES KEPT ACROSS TESTS AND RUNS, so a game that takes most of a minute to build is
    # built once for every test that plays it, and again only when something it is built from changes:
    #
    #   BUILDS = VBlank::Testing::CartridgeCache.new(".cache/builds", inputs: ["games/rocket/rocket.gbc"])
    #   rom = BUILDS.cartridge(Rocket.game, console: :gbc)   # built the first time, kept after
    #   BUILDS.cartridge_path(Rocket.game, console: :gbc)    # ...and as a file, for an emulator to open
    #
    # THE KEY is everything the cartridge is made of: its title, code, maker and build options, the
    # console, variant and settings, whether the build is measured, the library and emulators that
    # build it (every file under VBlank's lib and the emulators' sources, as they are on disk, so a
    # pinned gem and a checkout alike), the Ruby that runs them, and the files the game names in
    # +inputs+ by their contents (what a build reads that is not the game's code: a player's copy of
    # the original, say). And the game itself, one of two ways:
    #
    # - by its PROGRAM, unless said: the tree the game's block builds for that console, so a change
    #   to the game's code that changes what it builds changes the key and one that does not, does
    #   not. Making the tree runs the game's block, which is most of a build for a big game, once in
    #   each process and Ractor that asks.
    # - by its SOURCES, when +sources+ names the game's files (globs): their contents, read once when
    #   the cache is made, so asking costs nothing, and any edit to them builds again.
    #
    # ONCE IN EVERY PROCESS AND EVERY RACTOR: a cartridge built or read is kept for the length of the
    # run in the Ractor that asked (tests in Ractors each have their own), and on disk in +folder+
    # for every process and every later run. Two processes or Ractors that want one cartridge at once
    # take a lock on its file: the first builds it, and the rest wait and read what it kept. A file is
    # written under a name of its own and then renamed, so a run stopped half way leaves no
    # half-written cartridge.
    #
    # WHAT IS KEPT is pruned: everything a different library built, as soon as this one stores a
    # cartridge, and a cartridge no run has read for EXPIRE_DAYS. NO_BUILD_CACHE=1 builds every
    # cartridge afresh, once in each process and Ractor, and keeps what it built, to check that a
    # cached run and a fresh one agree. A built cartridge may hold the original's data, so +folder+
    # must be one git ignores.
    #
    # A CartridgeCache holds nothing that changes, so one in a constant can be read from any Ractor.
    class CartridgeCache
      EXPIRE_DAYS = 7
      SECONDS_A_DAY = 86_400
      SKIP_SETTING = "NO_BUILD_CACHE"
      # The name of the folder a library's cartridges are kept in: the start of its digest. Only
      # folders named so are ever pruned, whatever else is in the folder the game names.
      LIBRARY_FOLDER = /\A\h{16}\z/

      # The files of the library and of the emulators that build and measure a cartridge.
      FRAMEWORK_GLOBS = ["lib/**/*", "ext/**/*", "core/**/*", "ruby-*-emulator/{lib,ext,core}/**/*"].freeze
      # Where each emulator gem the bundle holds is, read once as the library loads: a gem a game loads
      # apart from VBlank is read where it is. (A test in a Ractor cannot ask rubygems.)
      EMULATOR_ROOTS = Ractor.make_shareable(%w[ruby-gba-emulator ruby-snes-emulator ruby-genesis-emulator ruby-ps1-emulator]
                                              .filter_map { |name| Gem.loaded_specs[name]&.full_gem_path })

      def initialize(folder, inputs: [], sources: nil, env: ENV)
        framework = framework_digest
        @folder = File.join(File.expand_path(folder), framework[0, 16])
        @fresh = !env[SKIP_SETTING].to_s.empty?
        @inputs = files_digest(inputs.map { File.expand_path(it) })
        @sources = sources && files_digest(sources.flat_map { Dir.glob(it) }.sort)
        @framework = framework
        Ractor.make_shareable(self)
      end

      # The cartridge +game+ (a VBlank.game) builds for +console+ (and +variant+) with +settings+,
      # measured when +profile+ is true, as its build gives it back.
      def cartridge(game, console:, variant: game.variant_for(console), settings: {}, profile: false)
        key = key_for(game, console, variant, settings, profile)
        built = (::Ractor.current[:vblank_cartridge_cache] ||= {})
        built[[@folder, key]] ||= read_or_build(key) do
          game.build_rom(out: nil, err: nil, profile: profile, settings: settings, console: console, variant: variant)
        end
      end

      # The same cartridge as a file, for an emulator to open: written beside what is kept, once.
      def cartridge_path(game, console:, variant: game.variant_for(console), settings: {}, profile: false)
        rom = cartridge(game, console: console, variant: variant, settings: settings, profile: profile)
        path = entry_path(key_for(game, console, variant, settings, profile)).sub(/\.marshal\z/, Console.described(console).extension)
        rom.write(path) unless File.file?(path)
        path
      end

      # Whether a cartridge for these is kept on disk, so asking for it builds nothing.
      def cached?(game, console:, variant: game.variant_for(console), settings: {}, profile: false)
        !@fresh && File.file?(entry_path(key_for(game, console, variant, settings, profile)))
      end

      private

      # The key, worked out once in each Ractor for each game and build: by the program, that is the
      # slow part of asking.
      def key_for(game, console, variant, settings, profile)
        keys = (::Ractor.current[:vblank_cartridge_cache_keys] ||= {})
        keys[[game.object_id, @folder, console, variant, settings, profile]] ||= begin
          what = @sources || Marshal.dump(game.program(settings: settings, console: console, variant: variant))
          Digest::SHA256.new.update(@framework).update(Marshal.dump([game.title, game.code, game.maker, game.options.to_h,
                                                                     console, variant, settings, profile]))
                        .update(what).update(@inputs).hexdigest
        end
      end

      def files_digest(paths)
        paths.each_with_object(Digest::SHA256.new) { |path, digest| digest << path << Digest::SHA256.file(path).hexdigest }.hexdigest
      end

      # Every file of the library and the emulators, wherever each was loaded from: an emulator a game
      # loads as a gem of its own is read where that gem is.
      def framework_digest
        roots = [VBlank.root.to_s, *EMULATOR_ROOTS].uniq
        files = roots.flat_map { |root| FRAMEWORK_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) } }.select { File.file?(it) }.uniq.sort
        files.each_with_object(Digest::SHA256.new) { |path, digest| digest << File.basename(path) << File.binread(path) }
             .update("#{RUBY_VERSION} #{RUBY_PLATFORM}").hexdigest
      end

      def entry_path(key) = File.join(@folder, "#{key}.marshal")

      # The kept cartridge for +key+, or the block's, kept, when there is none or the run is fresh.
      def read_or_build(key)
        FileUtils.mkdir_p(@folder)
        path = entry_path(key)
        File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          if @fresh || !File.file?(path)
            store(path, yield)
          else
            File.utime(Time.now, Time.now, path)
          end
          Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- written by this class
        end
      end

      def store(path, cartridge)
        temporary = "#{path}.#{Process.pid}.#{::Ractor.current.object_id}"
        File.binwrite(temporary, Marshal.dump(cartridge))
        File.rename(temporary, path)
        prune
      end

      # What another library built, and what no run has read for EXPIRE_DAYS. A lock another process
      # holds is left where it is, so nobody waiting on it builds the cartridge a second time.
      def prune
        Dir.glob(File.join(File.dirname(@folder), "*")).each do |other|
          FileUtils.rm_rf(other) if other != @folder && File.directory?(other) && File.basename(other).match?(LIBRARY_FOLDER)
        end
        expired_before = Time.now - (EXPIRE_DAYS * SECONDS_A_DAY)
        Dir.glob(File.join(@folder, "*.marshal")).each do |entry|
          next unless File.mtime(entry) < expired_before

          FileUtils.rm_f(Dir.glob("#{entry.delete_suffix('.marshal')}.*").reject { it.end_with?(".lock") })
          remove_unheld_lock("#{entry}.lock")
        end
        # A cartridge a run stopped before renaming into place, a day or more ago.
        stale_before = Time.now - SECONDS_A_DAY
        Dir.glob(File.join(@folder, "*.marshal.*.*")).each { |left| FileUtils.rm_f(left) if File.mtime(left) < stale_before }
      end

      def remove_unheld_lock(path)
        File.open(path, File::RDWR) { |lock| File.delete(path) if lock.flock(File::LOCK_EX | File::LOCK_NB) }
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
