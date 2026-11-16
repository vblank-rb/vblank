# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # THE PART OF VBLANK A KEPT PACK IS KEYED ON (PackCache). A pack is made by building the port's
    # routine and playing it, on the interpreter, as C or as Ruby, so a change to the code that does
    # either must make it again. A change to code that does neither must not: digesting every file
    # under lib made every commit to VBlank replay a port's whole copy, though most commits are to
    # a console's lowering, which no unpacking ever runs.
    #
    # So the key digests every file under lib but those LEFT_OUT, by its place and its contents.
    # The list names what is left out rather than what is kept, so a file nobody has thought about
    # yet, a new folder above all, is in the key: forgetting costs a needless miss, never a stale hit.
    # test/interpreter/vblank/original/test_pack_library_left_out.rb holds the list to that: it
    # builds and plays made-up routines every way a build plays one, and fails if a left-out file
    # ran, was read, defined a value or a class the code that ran names, or changes a class the rest
    # of the library opens. A file it names goes in KEPT, or its folder comes off the list.
    #
    # Why not record which files a build runs and key on those? Ruby says which methods ran but not
    # which constants they read, so a table changed in a file whose methods never ran would hit; the
    # game as C is compiled from runtime files read as text in another process; and the key is
    # needed before the routine runs, so the list of files would be the last build's. A list a test
    # checks fails the same way only where no made-up routine reaches, and says so when it does.
    class PackLibrary
      # What no unpacking is built or played with, as places under lib/vblank: a folder ends in "/".
      LEFT_OUT = %w[
        ir/backends/gba.rb ir/backends/gba/
        ir/backends/gbc.rb ir/backends/gbc/
        ir/backends/snes.rb ir/backends/snes/
        ir/backends/genesis.rb ir/backends/genesis/
        ir/backends/js.rb ir/backends/js/
        cartridge.rb cartridge/
        diagnostics.rb diagnostics/
        live.rb live/
        network.rb network/
        playthroughs.rb playthroughs/
        bots.rb bots/
        cli.rb pager.rb
      ].freeze

      # Files inside a LEFT_OUT folder that a pack is made with all the same: the packed formats'
      # numbers (Original::Packing::GBA reads BiosCompress's), each lowering's list of what it
      # cannot make yet (Console::Kit), a build's options and players (read as a routine is built),
      # the records the interpreter makes of a sprite and of dropped sound, and the fingerprint of a
      # state file (Computer::StateFile).
      KEPT = %w[
        ir/backends/gba/bios_compress.rb
        ir/backends/gbc/lowering.rb ir/backends/snes/lowering.rb ir/backends/genesis/lowering.rb
        cartridge/options.rb cartridge/players.rb
        diagnostics/sprite_row.rb diagnostics/sound_drops.rb
        network/fingerprint.rb
      ].freeze

      # The library under +root+ (lib, holding vblank.rb and vblank/), leaving out +left_out+ but
      # +kept+, both as LEFT_OUT and KEPT are written.
      def initialize(root: VBlank.root.join("lib"), left_out: LEFT_OUT, kept: KEPT)
        @root = root.to_s
        @left_out = left_out
        @kept = kept
      end

      # Every file the key digests, as full paths, sorted.
      def files
        Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) && !left_out?(path) }.sort
      end

      # Whether the file at +path+ is left out of the key.
      def left_out?(path)
        place = path.delete_prefix(File.join(@root, "vblank", ""))
        return false if place == path || @kept.include?(place)

        @left_out.any? { |entry| entry.end_with?("/") ? place.start_with?(entry) : place == entry }
      end

      # The digest of #files, each by its place under the root and its contents, so a checkout and a
      # worktree of it share entries.
      def digest
        files.each_with_object(Digest::SHA256.new) do |path, digest|
          digest << path.delete_prefix(@root) << "\0" << File.binread(path)
        end.hexdigest
      end
    end
  end
end
