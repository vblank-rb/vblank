# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Playthroughs
    # Snapshots of consoles part way through a tape, kept across tests and runs, so a comparison
    # that asks about a moment deep in a game plays the frames before it once and not on every run:
    #
    #   SNAPSHOTS = VBlank::Playthroughs::SnapshotCache.new(".cache/snapshots")
    #   tape.compare(ours, original, starting_after: 4194, snapshots: SNAPSHOTS)
    #
    # A snapshot is the emulator's own record of the whole console (Diagnostics::Verifier#save_state):
    # every byte of its memory and where its processor is. Put back, the console plays on from that
    # frame as if it had played every frame before it.
    #
    # ### What a snapshot is kept under
    #
    # Everything that decides what the console holds on that frame, so a snapshot made of anything
    # else is never read: the console and the build of its emulator (Console::Kit#emulator_build),
    # every byte of the cartridge, the controller adapter it was opened with (`multitap:`), the save
    # it held as the console was switched on, and the buttons held on every frame up to the frame.
    # The save folder is not part of it: every reader opens its cartridge under a file name of its
    # own, so it starts with no save left by another run. A cartridge built again after a change to
    # its game is new bytes, and makes its snapshot again once; an original that never changes makes
    # its own once ever.
    #
    # ### Many processes and Ractors
    #
    # Two that want one snapshot at once take a lock on its file: the first plays to the frame and
    # writes it, and the rest wait and read it. A snapshot is written under a name of its own and
    # then renamed, so a run stopped half way leaves no half-written one. The cache holds nothing
    # that changes, so one in a constant can be read from any Ractor.
    #
    # ### When one will not load
    #
    # A snapshot the emulator refuses (a libmgba installed again, a file cut short) is played to
    # again from power-on and written again, and the logger says so once for that snapshot
    # (VBlank.logger, under "snapshots").
    #
    # NO_SNAPSHOT_CACHE=1 plays every start from power-on, and keeps what it played to, to check
    # that a run from snapshots and a fresh one agree. A snapshot that no run has read for
    # EXPIRE_DAYS is removed. A snapshot of an original's cartridge holds the original's data, so
    # +folder+ must be one git ignores.
    class SnapshotCache
      EXPIRE_DAYS = 7
      SECONDS_A_DAY = 86_400
      SKIP_SETTING = "NO_SNAPSHOT_CACHE"
      EXTENSION = ".state"
      # The version of what goes into a key: a change to how a snapshot is made changes it.
      KEY_VERSION = 1

      # The buttons held over a stretch of frames: how many frames, and the key mask
      # (Playthrough.key_mask).
      Presses = Data.define(:frames, :keys)

      attr_reader :folder

      def initialize(folder, env: ENV)
        @folder = File.expand_path(folder).freeze
        @fresh = !env[SKIP_SETTING].to_s.empty?
        Ractor.make_shareable(self)
      end

      # Whether a snapshot is never read, only made (NO_SNAPSHOT_CACHE).
      def fresh? = @fresh

      # A console of +cartridge+ on the frame after +presses+ (a list of Presses), as +open+ (a block)
      # switches one on: the snapshot of it put back where one is kept, and else the presses played
      # on it and the snapshot written. +save+ is what the save memory held at power-on, nil for none.
      def console_after(presses, cartridge, save: nil, &open)
        path = File.join(@folder, "#{key_for(presses, cartridge, save)}#{EXTENSION}")
        FileUtils.mkdir_p(@folder)
        File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          kept = loaded_from(path, &open) unless @fresh
          kept || played_and_stored(path, presses, &open)
        end
      end

      private

      # The console with the snapshot at +path+ put back, or nil where there is none or it would not
      # load. A console that refused it is shut, since what it holds is part one state and part another.
      def loaded_from(path)
        return nil unless File.file?(path)

        game = yield
        begin
          game.load_state(path)
          File.utime(Time.now, Time.now, path)
          game
        rescue StandardError => e
          game.close
          VBlank.logger.warn("snapshots") { "The snapshot #{path} did not load (#{e.message}). It is played to again from power-on." }
          nil
        end
      end

      def played_and_stored(path, presses)
        game = yield
        presses.each { |held| game.step(held.frames, keys: held.keys) }
        temporary = "#{path}.#{Process.pid}.#{::Ractor.current.object_id}"
        game.save_state(temporary)
        File.rename(temporary, path)
        prune
        game
      end

      def key_for(presses, cartridge, save)
        console = cartridge.console
        multitap = cartridge.respond_to?(:multitap?) && cartridge.multitap?
        save_said = save && [Digest::SHA256.hexdigest(save.to_sav), (save.clock_state if save.respond_to?(:clock_state))]
        parts = [KEY_VERSION, console, Console.for(console).emulator_build, Digest::SHA256.hexdigest(cartridge.buffer),
                 multitap, save_said, presses.map { |held| [held.frames, held.keys] }]
        Digest::SHA256.hexdigest(parts.inspect)
      end

      # What no run has read for EXPIRE_DAYS, and what a run stopped before renaming into place.
      def prune
        expired_before = Time.now - (EXPIRE_DAYS * SECONDS_A_DAY)
        Dir.glob(File.join(@folder, "*#{EXTENSION}")).each do |kept|
          FileUtils.rm_f(kept) if modified_before?(kept, expired_before)
        end
        stale_before = Time.now - SECONDS_A_DAY
        Dir.glob(File.join(@folder, "*#{EXTENSION}.*.*")).each { |left| FileUtils.rm_f(left) if modified_before?(left, stale_before) }
      end

      # Another process can remove a file between the glob that found it and this read.
      def modified_before?(path, time)
        File.mtime(path) < time
      rescue Errno::ENOENT
        false
      end
    end
  end
end
