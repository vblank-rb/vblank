# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Original
    # WHAT A PORT'S UNPACKING ROUTINE WROTE, CACHED BETWEEN BUILDS. Built all-in-one, the routine
    # runs as the game is built (Builder::DataPacks#play_unpacking), which for a big port is a long
    # wait every build, though neither the player's copy nor the routine changed. A game that names
    # a folder caches the pack file there and a later build hits:
    #
    #   pack = data_pack(from: ORIGINAL, version: "1", cache: ".cache/packs") { |slots| ... }
    #
    # THE KEY is everything the bytes are made from: the unpacking program, which holds the routine,
    # the slots and the copy's size, written out as IR::Dump writes a program, so a change to any of
    # them misses; a digest of the copy's bytes themselves, worked out here rather than taken from
    # what the copy says its SHA-1 is (the program reads the copy from a file, Original::Unpacking,
    # so a copy of many megabytes adds nothing to the key's text); the library, every file under its
    # lib by its place there and its contents, since the interpreter that runs the routine is part
    # of it (so a checkout and a worktree of it share entries); the Ruby; and the SHA-1 and build
    # version the pack's header names. The folder must be one git ignores, since what is cached is
    # the original's data.
    #
    # AN ENTRY IS THE PACK FILE ITSELF (Original::Pack), which the routine's run writes straight
    # into the folder (Unpacking#write_pack_fastest), so a pack of hundreds of megabytes is never
    # held twice to be kept.
    #
    # Each change to the library misses once and writes a new entry, so entries are pruned: one no
    # build has read for EXPIRE_DAYS goes when the next is stored, and so does a half-written one
    # left by a build that stopped. Two builds at once, in two processes, Ractors or threads, may each
    # miss and each store the same bytes: an entry is written under a name of its own and then renamed,
    # so neither reads half of one, and an entry that cannot be read is made again. A PackCache
    # holds nothing that changes, so it is made for each build.
    class PackCache
      ENTRY_EXTENSION = ".pack"
      PARTIAL_EXTENSION = ".part"
      EXPIRE_DAYS = 7
      SECONDS_A_DAY = 86_400

      def initialize(folder)
        @folder = File.expand_path(folder)
      end

      # The pack (an Original::Pack) +unpacking+ (an Original::Unpacking, holding the copy it reads)
      # makes for the copy whose SHA-1 is +sha1+ and the build +build_version+: the cached entry on
      # a hit; else the one the block writes to the file at the path it is handed, which is then stored.
      def pack(unpacking, sha1:, build_version:, &write)
        path = File.join(@folder, "#{key(unpacking, sha1, build_version)}#{ENTRY_EXTENSION}")
        read(path) || store(path, &write)
      end

      # What a pack that only keeps slots names in its header, where there is no copy's SHA-1 or
      # build to name (#slot_bytes).
      SLOTS_ONLY_SHA1 = ("0" * 40).freeze
      SLOTS_ONLY_VERSION = "slots"

      # Each slot's bytes for +unpacking+, by name: the cached entry's on a hit, else the block's
      # (a Hash of them, as Unpacking#slot_bytes_in gives), which are then stored. For a game's own
      # test that plays the routine itself and wants its slots, not a pack file; the entry is a
      # pack file all the same, named for no copy and no build.
      def slot_bytes(unpacking)
        made = pack(unpacking, sha1: SLOTS_ONLY_SHA1, build_version: SLOTS_ONLY_VERSION) do |path|
          Pack.holding(yield, sha1: SLOTS_ONLY_SHA1, build_version: SLOTS_ONLY_VERSION).write(path)
        end
        made.slots
      end

      private

      def key(unpacking, sha1, build_version)
        digest = Digest::SHA256.new
        digest << library_digest << "\0" << RUBY_VERSION << " " << RUBY_PLATFORM << "\0"
        digest << Digest::SHA256.hexdigest(unpacking.copy_bytes) << "\0"
        digest << sha1.to_s << "\0" << build_version.to_s << "\0"
        digest << IR::Dump.source(unpacking.program)
        digest.hexdigest
      end

      def library_digest
        lib = VBlank.root.join("lib").to_s
        files = Dir.glob(File.join(lib, "**", "*")).select { |path| File.file?(path) }.sort
        files.each_with_object(Digest::SHA256.new) do |path, digest|
          digest << path.delete_prefix(lib) << File.binread(path)
        end.hexdigest
      end

      # A hit's pack, its use marked so pruning keeps it; nil on a miss or an entry that cannot be read.
      def read(path)
        return unless File.file?(path)

        cached = Pack.read(path)
        File.utime(Time.now, Time.now, path)
        cached
      rescue WrongPack, ArgumentError, Errno::ENOENT
        nil
      end

      # The pack the block writes, stored at +path+. It is written under a name of its own and renamed
      # once whole. A folder that cannot be written loses the entry, never the build: the pack is
      # made somewhere else and handed on, with one line saying the next build will run the
      # routine again.
      def store(path)
        # Named for the thread, which tells apart builds in other processes, other Ractors (each has
        # threads of its own) and other threads of this one, so no build renames another's file.
        temporary = "#{path}.#{Process.pid}.#{Thread.current.object_id}#{PARTIAL_EXTENSION}"
        begin
          FileUtils.mkdir_p(@folder)
          File.binwrite(temporary, "")
        rescue SystemCallError => e
          warn_not_cached(e)
          return Pack.read_from_temporary_file { |elsewhere| yield elsewhere }
        end
        yield temporary
        made = Pack.read(temporary)
        store_entry(temporary, path)
        made
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      # The whole entry at +temporary+ renamed to +path+, and the old entries pruned.
      def store_entry(temporary, path)
        File.rename(temporary, path)
        prune
      rescue SystemCallError => e
        warn_not_cached(e)
      end

      def warn_not_cached(error)
        warn "The data pack was not cached in #{@folder}: #{error.message}. The next build unpacks the copy again."
      end

      def prune
        expired = Time.now - (EXPIRE_DAYS * SECONDS_A_DAY)
        Dir.glob(File.join(@folder, "*{#{ENTRY_EXTENSION},#{PARTIAL_EXTENSION}}")).each do |path|
          File.delete(path) if File.mtime(path) < expired
        rescue Errno::ENOENT
          next
        end
      end
    end
  end
end
