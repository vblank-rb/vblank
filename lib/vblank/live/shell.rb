# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Live
    # A SHELL PLAYED AS RUBY: what Original::Shell has a runtime do, done in this process on a
    # device (a window, or Headless in a test). vblank run --shell makes one from the build
    # (Shell.from); a game written out as one Ruby file with --shell carries the same, its parts
    # written out as text (Backends::Ruby#script), and needs nothing of the library but what it
    # carries: Session, LiveGame, IR::StartFile, Original::Releases and Original::ShellFacts.
    #
    # #play goes: the pack kept in the game's folder, if it passes the check, is handed to the game
    # and the game plays. Otherwise the menu plays until the player picks a line. LOAD ROM asks
    # +choose_copy+ for a file; one that is not a release the game reads is refused in words handed
    # to +refused+, and the menu plays again. A release the game reads is unpacked by its unpacking,
    # played as fast as the machine goes, which draws its own progress bar; the pack is written to
    # the folder and handed to the game. SETTINGS calls +open_settings+ (the window opens its menu),
    # and the menu plays again.
    class Shell
      # A file a player picked that is not a copy the game reads, or one whose unpacking went wrong.
      class Refused < StandardError; end

      # +facts+ are the Original::ShellFacts every runtime is made from. +game+, +menu+ and each of
      # +unpackings+ (in the order of their numbers) are the programs as Ruby
      # (Backends::Ruby#live_source), each made a LiveGame afresh every time it plays.
      def initialize(facts:, game:, menu:, unpackings:)
        @facts = facts
        @releases = facts.original_releases
        @game = game
        @menu = menu
        @unpackings = unpackings
      end

      # The name of the folder the pack is kept in (Original::Shell.folder_name).
      def folder = @facts.folder

      # The Live::Shell for +shell+, an Original::Shell, its programs written as Ruby here.
      def self.from(shell)
        ruby = IR::Backends::Ruby.new
        new(facts: shell.facts, game: ruby.live_source(shell.game), menu: ruby.live_source(shell.menu),
            unpackings: shell.unpackings.map { |unpacking| ruby.live_source(unpacking.program) })
      end

      # Plays the shell on +device+ until the player stops it: the game, once there is a pack in
      # +folder_path+ (made here if it is not there yet). +choose_copy+ is called with no arguments
      # when LOAD ROM is chosen and gives back the path of the file picked, or nil when none was;
      # +refused+ is handed the words for a file refused, or a kept pack that cannot be read;
      # +open_settings+ is called when SETTINGS is chosen. +play_game+ is handed the game, as a
      # LiveGame holding its pack, and plays it (a Session's #play); its answer is #play's.
      def play(device, folder_path:, choose_copy:, refused:, open_settings: -> {}, play_game: nil)
        play_game ||= ->(game) { Session.new(game: game).play(device) }
        pack = kept_pack(folder_path, refused)
        until pack
          case play_menu(device)
          when :load_rom then pack = load_copy(device, folder_path, choose_copy, refused)
          when :settings then open_settings.call
          else return nil
          end
        end
        play_game.call(IR::Backends::Ruby::LiveGame.new(@game).hand_file(pack))
      end

      # The pack this shell would make from the copy +bytes+, a file called +named+, unpacked on
      # +device+; Refused, in the words a player is told, when it is not a release the game reads.
      # Nil when the device stopped the unpacking before its end.
      def pack_from_copy(named, bytes, device)
        bytes = bytes.b
        refusal = @releases.size_refusal(named, bytes.bytesize) and raise Refused, refusal
        sha1 = Digest::SHA1.hexdigest(bytes)
        refusal = @releases.digest_refusal(named, sha1) and raise Refused, refusal

        unpacking = IR::Backends::Ruby::LiveGame.new(@unpackings.fetch(@facts.release_with_sha1(sha1).unpacking)).hand_file(bytes)
        rate = Session.new(game: unpacking, uncapped: true, keep_last_picture: false).play(device)
        return nil unless rate.stopped_itself?

        state = unpacking.state
        names = @facts.unpacking
        fault = state.vars.fetch(names.fault_kind)
        unless state.vars.fetch(names.finished) == 1 && fault.zero?
          raise Refused, Original::ShellFacts.unpacking_stopped_message(named, fault)
        end

        @facts.pack_for(sha1, state.lists.fetch(names.bytes).map { |item| item & 0xFF }.pack("C*"))
      end

      private

      # The pack kept in +folder_path+ when it passes the check, else nil; a file there that does
      # not is handed to +refused+ (the menu then asks for the copy again).
      def kept_pack(folder_path, refused)
        path = File.join(folder_path, @facts.pack_file)
        return nil unless File.file?(path)

        bytes = File.binread(path)
        refusal = @facts.pack_rules.refusal(bytes)
        return bytes unless refusal

        refused.call(Original::ShellFacts.kept_pack_refused_message(@facts.title, path, refusal))
        nil
      end

      # Which line the player chose on the menu, :load_rom or :settings, or nil when the device
      # stopped it.
      def play_menu(device)
        menu = IR::Backends::Ruby::LiveGame.new(@menu)
        rate = Session.new(game: menu, keep_last_picture: false).play(device)
        return nil unless rate.stopped_itself?

        { @facts.menu.load_rom => :load_rom, @facts.menu.settings => :settings }[menu.state.vars.fetch(@facts.menu.choice_variable)]
      end

      # The pack made from the file +choose_copy+ picks and written to +folder_path+, or nil when
      # nothing was picked, the file was refused, or the device stopped the unpacking.
      def load_copy(device, folder_path, choose_copy, refused)
        path = choose_copy.call or return nil
        bytes = begin
          File.binread(path)
        rescue SystemCallError => e
          raise Refused, Original::ShellFacts.unreadable_message(path, e.message)
        end
        pack = pack_from_copy(path, bytes, device) or return nil
        write_pack(folder_path, pack)
        pack
      rescue Refused, SystemCallError => e # SystemCallError: the pack cannot be written
        refused.call(e.message)
        nil
      end

      # Written to a file beside it and then moved into place, so a pack is never left half written.
      def write_pack(folder_path, pack)
        FileUtils.mkdir_p(folder_path)
        path = File.join(folder_path, @facts.pack_file)
        File.binwrite("#{path}.writing", pack)
        File.rename("#{path}.writing", path)
      end
    end
  end
end
