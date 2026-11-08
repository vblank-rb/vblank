# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Original
    # WHAT A PORT'S UNPACKING ROUTINE WROTE, CACHED BETWEEN BUILDS. Built all-in-one, the routine
    # runs on the interpreter as the game is built (Builder::DataPacks#unpack_on_interpreter), which
    # for a big port is most of a minute every build, though neither the player's copy nor the
    # routine changed. A game that names a folder caches each slot's bytes there and a later build
    # hits:
    #
    #   pack = data_pack(from: ORIGINAL, version: "1", cache: ".cache/packs") { |slots| ... }
    #
    # THE KEY is everything the bytes are made from: the unpacking program, which holds the copy's
    # bytes, the routine and the slots, written out as IR::Dump writes a program, so a change to any
    # of them misses; the copy's SHA-1 besides; the library, every file under its lib by its place
    # there and its contents, since the interpreter that runs the routine is part of it (so a
    # checkout and a worktree of it share entries); and the Ruby. The folder must be one git
    # ignores, since what is cached is the original's data.
    #
    # Each change to the library misses once and writes a new entry, so entries are pruned: one no
    # build has read for EXPIRE_DAYS goes when the next is stored, and so does a half-written one
    # left by a build that stopped. Two builds at once, in two processes or Ractors, may each miss
    # and each store the same bytes: an entry is written under a name of its own and then renamed,
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

      # Each slot's bytes for +unpacking+ (an Original::Unpacking) of the copy whose SHA-1 is
      # +copy_sha1+: the cached entry on a hit, else the block's, which is then stored.
      def slot_bytes(unpacking, copy_sha1)
        path = File.join(@folder, "#{key(unpacking, copy_sha1)}#{ENTRY_EXTENSION}")
        cached = read(path)
        return cached if cached

        unpacked = yield
        store(path, unpacked)
        unpacked
      end

      private

      def key(unpacking, copy_sha1)
        digest = Digest::SHA256.new
        digest << library_digest << "\0" << RUBY_VERSION << " " << RUBY_PLATFORM << "\0" << copy_sha1 << "\0"
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

      # A hit's bytes, its use marked so pruning keeps it; nil on a miss or an entry that cannot be read.
      def read(path)
        return unless File.file?(path)

        cached = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- written by #store
        File.utime(Time.now, Time.now, path)
        cached
      rescue TypeError, ArgumentError, EOFError, Errno::ENOENT
        nil
      end

      # A folder that cannot be written loses the entry, never the build: the routine has run, and
      # its bytes are handed on, with one line saying the next build will run it again.
      def store(path, slots)
        FileUtils.mkdir_p(@folder)
        temporary = "#{path}.#{Process.pid}.#{Ractor.current.object_id}#{PARTIAL_EXTENSION}"
        File.binwrite(temporary, Marshal.dump(slots))
        File.rename(temporary, path)
        prune
      rescue SystemCallError => e
        warn "The data pack was not cached in #{@folder}: #{e.message}. The next build unpacks the copy again."
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
