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
    # the slots and the copy's size, written out as IR::Dump writes a program, with the DEFAULTS of
    # the record classes it holds, which the dump leaves out (#program_source), so a change to any of
    # them misses; a digest of the copy's bytes themselves, worked out here rather than taken from
    # what the copy says its SHA-1 is (the program reads the copy from a file, Original::Unpacking,
    # so a copy of many megabytes adds nothing to the key's text); the part of the library a pack is
    # built and played with, each file by its place under lib and its contents (PackLibrary, which
    # says which files and why), so a checkout and a worktree of it share entries; the Ruby; and the
    # SHA-1 and build version the pack's header names. The folder must be one git ignores, since
    # what is cached is the original's data.
    #
    # AN ENTRY IS THE PACK FILE ITSELF (Original::Pack), which the routine's run writes straight
    # into the folder (Unpacking#write_pack_fastest), so a pack of hundreds of megabytes is never
    # held twice to be kept.
    #
    # Each change to that part of the library misses once and writes a new entry, so entries are
    # pruned: one no build has read for EXPIRE_DAYS goes when the next is stored, and so does a
    # half-written one left by a build that stopped. Two builds at once, in two processes, Ractors or threads, may each
    # miss and each store the same bytes: an entry is written under a name of its own and then renamed,
    # so neither reads half of one, and an entry that cannot be read is made again. A PackCache
    # keeps only the digests of the library and the copies it has keyed, and is made for each build.
    #
    # A routine the game gives in parts (`slots.fill_from_copy :music do ... end`) is kept a part
    # at a time, so a change to one part plays that part again and not the rest (#pack_by_parts).
    class PackCache
      ENTRY_EXTENSION = ".pack"
      PARTIAL_EXTENSION = ".part"
      EXPIRE_DAYS = 7
      SECONDS_A_DAY = 86_400

      # +library+ is the part of VBlank the key digests (a PackLibrary); a test hands one of a made-up
      # library folder.
      def initialize(folder, library: PackLibrary.new)
        @folder = File.expand_path(folder)
        @library = library
      end

      # The pack (an Original::Pack) +unpacking+ (an Original::Unpacking, holding the copy it reads)
      # makes for the copy whose SHA-1 is +sha1+ and the build +build_version+: the cached entry on
      # a hit; else the one the block writes to the file at the path it is handed, which is then stored.
      #
      # Where +parts+ (an UnpackingParts) is given, the routine's parts are cached apart: see
      # #pack_by_parts. The block is then handed, after the path, the Unpacking to play and the
      # names of the parts it plays.
      def pack(unpacking, sha1:, build_version:, parts: nil, &write)
        return pack_by_parts(unpacking, parts, sha1, build_version, &write) if parts

        path = File.join(@folder, "#{key(unpacking, sha1, build_version)}#{ENTRY_EXTENSION}")
        read(path) || store(path) { |temporary| yield temporary, unpacking, nil }
      end

      # What a pack that only keeps slots names in its header, where there is no copy's SHA-1 or
      # build to name (#slot_bytes).
      SLOTS_ONLY_SHA1 = ("0" * 40).freeze
      SLOTS_ONLY_VERSION = "slots"

      # What a key holds of +program+: the program as IR::Dump writes it, and the DEFAULTS of the
      # record classes it holds, which the dump leaves out (IR::Dump.record_defaults_source), so the
      # key changes with what the program means. UnpackingParts keys a part's program the same way.
      def self.program_source(program) = "#{IR::Dump.source(program)}\0#{IR::Dump.record_defaults_source(program)}"

      # Each slot's bytes for +unpacking+, by name: the cached entry's on a hit, else the block's
      # (a Hash of them, as Unpacking#slot_bytes_in gives), which are then stored. For a game's own
      # test that plays the routine itself and wants its slots, not a pack file; the entry is a
      # pack file all the same, named for no copy and no build.
      #
      # Where +parts+ (an UnpackingParts, DSL::DataPack#unpacking_parts) is given, the routine is
      # cached a part at a time, as #pack caches it. The block is handed the Unpacking to play and
      # the names of the parts it plays (nil without parts), and gives back that Unpacking's slots.
      def slot_bytes(unpacking, parts: nil)
        made = pack(unpacking, sha1: SLOTS_ONLY_SHA1, build_version: SLOTS_ONLY_VERSION, parts: parts) do |path, playing, names|
          Pack.holding(yield(playing, names), sha1: SLOTS_ONLY_SHA1, build_version: SLOTS_ONLY_VERSION).write(path)
        end
        made.slots
      end

      private

      # A ROUTINE IN PARTS (UnpackingParts) is cached a part at a time. A part's entry is a pack
      # holding the slots it is the last part to write (UnpackingParts#slots_of). Its key is the
      # whole routine's, with the programs of that part and every part it needs
      # (UnpackingParts#inputs_of), each built alone (UnpackingParts#key_source), in place of the
      # whole program, the part's name, and the slots
      # its entry holds (a later part that stops writing a slot makes it this part's): so a change
      # to a part misses for it and for every part that needs it, and for no other. The parts that
      # missed are played in one program with all they need (UnpackingParts#played_for), and each
      # one's slots are stored. The pack is put together from the entries: each slot from the part
      # last to write it, a slot copied as it is from the copy, and a slot no part writes as
      # zeros, as the whole routine leaves them.
      #
      # Where the parts played go wrong, the whole routine is played instead and nothing is kept,
      # so the build stops with the error the whole routine stops with.
      def pack_by_parts(unpacking, parts, sha1, build_version, &write)
        paths = parts.names.to_h { |name| [name, part_entry_path(unpacking, parts, name, sha1, build_version)] }
        kept = paths.to_h { |name, path| [name, read(path)] }.compact
        missed = parts.names - kept.keys
        unless missed.empty?
          played = parts.played_for(missed)
          made = play_parts(parts, played, &write)
          return play_whole(unpacking, parts, &write) unless made

          missed.each { |name| kept[name] = store_part(paths.fetch(name), made, parts.slots_of(name)) }
        end
        assemble_pack(unpacking, parts, kept, sha1, build_version)
      end

      # The pack the block writes playing the parts +played+, or nil where they went wrong.
      def play_parts(parts, played)
        Pack.read_from_temporary_file { |path| yield path, parts.unpacking_of(played), played }
      rescue StandardError
        # Must rescue every error: the whole routine, played next, raises the one the build stops with.
        nil
      end

      def play_whole(unpacking, parts)
        Pack.read_from_temporary_file { |path| yield path, unpacking, parts.names }
      end

      # The part's entry: the slots +slot_names+ of +made+, stored at +path+.
      def store_part(path, made, slot_names)
        entry = Pack.holding(slot_names.to_h { |name| [name, made.bytes_of(name)] }, sha1: made.rom_sha1,
                                                                                    build_version: made.build_version)
        store(path) { |temporary| entry.write(temporary) }
      end

      def assemble_pack(unpacking, parts, kept, sha1, build_version)
        slot_bytes = unpacking.slots.to_h do |slot|
          writer = parts.last_writer_of(slot.name)
          bytes = if writer then kept.fetch(writer).bytes_of(slot.name)
                  elsif slot.filled_by_routine? then "\0".b * slot.byte_size
                  else slot.cut_from(unpacking.copy_bytes)
                  end
          [slot.name, bytes]
        end
        Pack.holding(slot_bytes, sha1: sha1, build_version: build_version)
      end

      def part_entry_path(unpacking, parts, name, sha1, build_version)
        digest = key_digest(unpacking, sha1, build_version)
        digest << "part " << name.to_s << "\0" << parts.slots_of(name).join(" ") << "\0" << parts.key_source(name)
        File.join(@folder, "#{digest.hexdigest}#{ENTRY_EXTENSION}")
      end

      def key(unpacking, sha1, build_version)
        digest = key_digest(unpacking, sha1, build_version)
        digest << PackCache.program_source(unpacking.program)
        digest.hexdigest
      end

      # The key's digest of everything but the program: the library, the Ruby, the copy, and the
      # SHA-1 and build version the pack's header names.
      # Worked out once for every part's key, since the library and the copy can be many megabytes.
      def key_digest(unpacking, sha1, build_version)
        library = @library_digest ||= @library.digest
        copy = (@copy_digests ||= {}.compare_by_identity)[unpacking.copy_bytes] ||= Digest::SHA256.hexdigest(unpacking.copy_bytes)
        digest = Digest::SHA256.new
        digest << library << "\0" << RUBY_VERSION << " " << RUBY_PLATFORM << "\0"
        digest << copy << "\0"
        digest << sha1.to_s << "\0" << build_version.to_s << "\0"
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
