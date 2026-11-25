# frozen_string_literal: true

# Required here and not where it is used: see the note at the top of verifier.rb.
require "tempfile"

module VBlank
  module Diagnostics
    # The cartridge file a reader (Verifier) writes for the emulator, the save file the emulator
    # keeps beside it, and the emulator playing them, taken down in the one order every system
    # allows: the emulator shut first, then its files removed.
    #
    # ### Why the order matters
    #
    # The emulator keeps the cartridge file open for as long as it runs, and its save file too.
    # macOS and Linux let a program remove a file another holds open, so there the order never
    # shows. Windows refuses: the removal fails, the file stays in the temporary files, and when
    # the removal was a Tempfile's own clean-up as Ruby collected it, Ruby prints a warning for it.
    # A Tempfile cannot know about the emulator, so the cartridge file here is a plain file, and
    # this one object both shuts the emulator and removes the files.
    #
    # ### When it runs
    #
    # Verifier#close runs it at once. A reader nobody closes is common (a test reads a pixel and
    # is done), so it is also the reader's finalizer: Ruby runs it when the reader is collected,
    # or as the process ends, whichever comes first. It holds the emulator and the paths, never
    # the reader, since a finalizer that holds its object keeps it alive for ever.
    class PlayedCartridgeFile
      # Where the cartridge was written.
      attr_reader :path

      # A fresh, empty file in the machine's temporary files, named +verify…+ and ending in
      # +extension+ (`.gba`, `.gbc`), for a cartridge to be written into by path.
      def self.create(extension)
        file = Tempfile.create(["verify", extension])
        file.close # Written by path; Ruby keeps no handle of its own open on it
        new(file.path)
      end

      def initialize(path)
        @path = path
        @save_path = nil
        @emulator = nil
        @closed = false
      end

      # The emulator playing this file, shut before the file is removed.
      def playing_in(emulator)
        @emulator = emulator
        self
      end

      # A save file the emulator keeps that is removed with the cartridge, because nobody reads it
      # after the reader is done: one in the save directory every reader in the process shares.
      def removing_save(path)
        @save_path = path
        self
      end

      # Shut the emulator, then remove the files. Running it twice does nothing more.
      def close
        return if @closed

        @closed = true
        @emulator.close if @emulator.respond_to?(:close) && !@emulator.closed?
        [@path, @save_path].compact.each { |file| remove_file(file) }
        nil
      end

      # As a finalizer, which Ruby hands the collected object's id.
      def call(_object_id) = close

      private

      def remove_file(file)
        File.delete(file)
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
