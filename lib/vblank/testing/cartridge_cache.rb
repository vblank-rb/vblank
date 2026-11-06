# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

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
    # WHAT IT DID IS REPORTED at the end of a run (#report): every ask in every process and Ractor, a
    # hit or a miss, and for each miss how long it built and which part of its key changed since the
    # cartridge was last built, so a run that rebuilt more than a change should have says so.
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

      # WHAT A KEY IS MADE OF, each part's digest: the library's and emulators' files, the Ruby, the
      # game (its program or its sources), its title, code, maker and options, and the extra inputs.
      # A miss is explained by the parts that differ from the last key the same cartridge was built
      # under.
      KeyParts = Data.define(:library, :ruby, :game, :header, :inputs)
      PART_WORDS = Ractor.make_shareable({ "library" => "VBlank or an emulator changed", "ruby" => "Ruby changed",
                                           "game" => "the game changed", "header" => "its title, code, maker or options changed",
                                           "inputs" => "an extra input changed" })
      # One ask that reached the disk, as its log line holds it: the cartridge, whether it was read
      # (hit) or built (miss), why a miss missed, and how long the key and the build took.
      Ask = Data.define(:label, :result, :reason, :key_seconds, :build_seconds)

      # Why a miss missed, when no part says it.
      FIRST_BUILD_REASON = "not cached yet"
      SKIPPED_CACHE_REASON = "NO_BUILD_CACHE"

      def initialize(folder, inputs: [], sources: nil, env: ENV)
        library = library_digest
        @base = File.expand_path(folder)
        @folder = File.join(@base, library[0, 16])
        @fresh = !env[SKIP_SETTING].to_s.empty?
        @inputs = files_digest(inputs.map { File.expand_path(it) })
        # A glob such as "lib/**/*" matches the folders as well as the files; only files have contents.
        @sources = sources && files_digest(sources.flat_map { Dir.glob(it) }.select { File.file?(it) }.uniq.sort)
        @library = library
        @ruby = "#{RUBY_VERSION} #{RUBY_PLATFORM}"
        @made_at = Time.now - 1 # a second early, for a file system that keeps whole seconds
        Ractor.make_shareable(self)
      end

      # The cartridge +game+ (a VBlank.game) builds for +console+ (and +variant+) with +settings+,
      # measured when +profile+ is true, as its build gives it back. Each ask is counted, a hit or a
      # miss, for #report.
      #
      # +label+ is how the report names it, and what its last build is kept under to explain a miss:
      # the game's title, console and settings unless said. A game that builds many cartridges of
      # one title (a room, an area, the game from a save) names each, or every miss reads alike and
      # is explained against whichever was built last. The label is not part of the key: two asks
      # with one key are one cartridge, whatever each calls it.
      def cartridge(game, console:, variant: game.variant_for(console), settings: {}, profile: false, label: nil)
        started = clock
        key, parts = key_for(game, console, variant, settings, profile)
        key_seconds = clock - started
        label ||= label_for(game, console, variant, settings, profile)
        built = (::Ractor.current[:vblank_cartridge_cache] ||= {})
        kept = built[[object_id, key]]
        return kept if kept

        built[[object_id, key]] = read_or_build(key, label, parts, key_seconds) do
          game.build_rom(out: nil, err: nil, profile: profile, settings: settings, console: console, variant: variant)
        end
      end

      # WHAT THE CACHE DID THIS RUN, written to +out+, and its logs deleted: how many cartridges were
      # read from disk (hits) and how many built (misses), in every process and Ractor that asked since
      # this cache was made, how long working out their keys took, a line for each miss with how long
      # it built and why it missed, and the building the hits saved. Asking again for a cartridge a
      # Ractor already holds is neither. A game's test run calls it once, in the process the run
      # started in, as the run ends (`Minitest.after_run { BUILDS.report }`). Nothing is written when
      # nothing was asked. A log a stopped run left, a day old or more, is deleted unread.
      def report(out = $stdout)
        logs = Dir.glob(File.join(@base, "runs", "*.jsonl"))
        stale, current = logs.partition { File.mtime(it) < Time.now - SECONDS_A_DAY }
        current.select! { File.mtime(it) >= @made_at }
        asks = current.flat_map { |log| File.readlines(log).map { Ask.new(**JSON.parse(it, symbolize_names: true)) } }
        FileUtils.rm_f(stale + current)
        return if asks.empty?

        hits, misses = asks.partition { it.result == "hit" }
        out.puts "", "Build cache: #{hits.size} hits, #{misses.size} misses " \
                     "(keys #{format('%.1f', asks.sum(&:key_seconds))} s)"
        misses.sort_by { -it.build_seconds }.each do |miss|
          out.puts format("  miss %6.1f s  %-30s %s", miss.build_seconds, miss.reason, miss.label)
        end
        out.puts format("  hits saved about %.0f s of building", hits.sum(&:build_seconds)) unless hits.empty?
      end

      # The same cartridge as a file, for an emulator to open: written beside what is kept, once.
      # +label+ as #cartridge takes it.
      def cartridge_path(game, console:, variant: game.variant_for(console), settings: {}, profile: false, label: nil)
        rom = cartridge(game, console: console, variant: variant, settings: settings, profile: profile, label: label)
        path = entry_path(key_for(game, console, variant, settings, profile).first).sub(/\.marshal\z/, Console.described(console).extension)
        rom.write(path) unless File.file?(path)
        path
      end

      # Whether a cartridge for these is kept on disk, so asking for it builds nothing. It takes no
      # label: whether one is kept depends on the key alone.
      def cached?(game, console:, variant: game.variant_for(console), settings: {}, profile: false)
        !@fresh && File.file?(entry_path(key_for(game, console, variant, settings, profile).first))
      end

      private

      # The key and its parts, worked out once in each Ractor for each game and build: by the program,
      # that is the slow part of asking.
      def key_for(game, console, variant, settings, profile)
        keys = (::Ractor.current[:vblank_cartridge_cache_keys] ||= {})
        keys[[game.object_id, @folder, @inputs, @sources, console, variant, settings, profile]] ||= begin
          # The program as IR::Dump writes it, which is the same text for the same program every time.
          # Marshal is not: it writes an object it has met before as a link back, so a program whose
          # pieces are shared on one process and equal copies on another gave two keys.
          what = @sources || Digest::SHA256.hexdigest(IR::Dump.source(game.program(settings: settings, console: console, variant: variant)))
          header = Digest::SHA256.hexdigest(Marshal.dump([game.title, game.code, game.maker, game.options.to_h, console, variant,
                                                          settings, profile]))
          parts = KeyParts.new(library: @library, ruby: @ruby, game: what, header: header, inputs: @inputs)
          [Digest::SHA256.hexdigest(parts.to_h.values.join(" ")), parts]
        end
      end

      # How a report names a cartridge: the game, the console, and the settings that make it one.
      def label_for(game, console, variant, settings, profile)
        [game.title, console, variant, (settings.sort.to_h unless settings.empty?), ("measured" if profile)].compact.join(" ")
      end

      def files_digest(paths)
        paths.each_with_object(Digest::SHA256.new) { |path, digest| digest << path << Digest::SHA256.file(path).hexdigest }.hexdigest
      end

      # Every file of the library and the emulators, wherever each was loaded from: an emulator a game
      # loads as a gem of its own is read where that gem is.
      def library_digest
        roots = [VBlank.root.to_s, *EMULATOR_ROOTS].uniq
        files = roots.flat_map { |root| FRAMEWORK_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) } }.select { File.file?(it) }.uniq.sort
        files.each_with_object(Digest::SHA256.new) { |path, digest| digest << File.basename(path) << File.binread(path) }.hexdigest
      end

      def entry_path(key) = File.join(@folder, "#{key}.marshal")
      def seconds_path(key) = File.join(@folder, "#{key}.seconds")

      # The cartridge kept for +key+, or the block's, kept, when there is none or the run is fresh.
      def read_or_build(key, label, parts, key_seconds)
        FileUtils.mkdir_p(@folder)
        path = entry_path(key)
        File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          if @fresh || !File.file?(path)
            build_and_store(path, key, label, parts, key_seconds) { yield }
          else
            File.utime(Time.now, Time.now, path)
            log_hit(label, key, key_seconds)
          end
          Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- written by this class
        end
      end

      def build_and_store(path, key, label, parts, key_seconds)
        reason = @fresh ? SKIPPED_CACHE_REASON : miss_reason(label, parts)
        started = clock
        cartridge = yield
        build_seconds = clock - started
        temporary = "#{path}.#{Process.pid}.#{::Ractor.current.object_id}"
        File.binwrite(temporary, Marshal.dump(cartridge))
        File.rename(temporary, path)
        File.write(seconds_path(key), build_seconds.to_s)
        write_last_parts(label, parts)
        log_ask(Ask.new(label: label, result: "miss", reason: reason, key_seconds: key_seconds, build_seconds: build_seconds))
        prune
      end

      # WHY A CARTRIDGE MISSED: the parts of its key that differ from the key it was last built under,
      # by any run, or that it was never built.
      def miss_reason(label, parts)
        last = last_parts_path(label)
        return FIRST_BUILD_REASON unless File.file?(last)

        before = JSON.parse(File.read(last))
        changed = parts.to_h.select { |name, digest| before[name.to_s] != digest }.keys
        changed.empty? ? FIRST_BUILD_REASON : changed.map { PART_WORDS.fetch(it.to_s) }.join(" and ")
      end

      def write_last_parts(label, parts)
        FileUtils.mkdir_p(File.dirname(last_parts_path(label)))
        temporary = "#{last_parts_path(label)}.#{Process.pid}.#{::Ractor.current.object_id}"
        File.write(temporary, JSON.generate(parts.to_h))
        File.rename(temporary, last_parts_path(label))
      end

      def last_parts_path(label) = File.join(@base, "last", "#{Digest::SHA256.hexdigest(label)[0, 32]}.json")

      def log_hit(label, key, key_seconds)
        seconds = File.file?(seconds_path(key)) ? File.read(seconds_path(key)).to_f : 0.0
        log_ask(Ask.new(label: label, result: "hit", reason: nil, key_seconds: key_seconds, build_seconds: seconds))
      end

      # One ask, appended to this process's and Ractor's log, which #report reads with every other's.
      def log_ask(ask)
        log = File.join(@base, "runs", "#{Process.pid}-#{::Ractor.current.object_id}.jsonl")
        FileUtils.mkdir_p(File.dirname(log))
        File.open(log, "a") { |file| file.puts(JSON.generate(ask.to_h)) }
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
        # What a cartridge was last built from, for one no run has built for EXPIRE_DAYS.
        Dir.glob(File.join(@base, "last", "*.json")).each { |last| FileUtils.rm_f(last) if File.mtime(last) < expired_before }
      end

      def remove_unheld_lock(path)
        File.open(path, File::RDWR) { |lock| File.delete(path) if lock.flock(File::LOCK_EX | File::LOCK_NB) }
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
