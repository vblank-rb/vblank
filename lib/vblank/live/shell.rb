# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Live
    # A SHELL PLAYED AS RUBY: what Original::Shell says a runtime does, done in this process on a
    # device (a window, or Headless in a test). vblank run --shell makes one from the build
    # (Shell.from); a game written out as one Ruby file with --shell carries the same, its parts
    # written out as text (Backends::Ruby#script), and needs nothing of the library but what it
    # carries: Session, LiveGame, IR::StartFile and Original::Releases.
    #
    # #play goes: the pack kept in the game's folder, if it is one this shell reads, is handed to the
    # game and the game plays. Otherwise the menu plays until the player picks a line. LOAD ROM asks
    # +choose_copy+ for a file; one that is not a release the game reads is refused in words handed
    # to +refused+, and the menu plays again. A release the game reads is unpacked by its unpacking,
    # played as fast as the machine goes, which draws its own progress bar; the pack is written to
    # the folder and handed to the game. SETTINGS calls +open_settings+ (the window opens its menu),
    # and the menu plays again.
    class Shell
      # The names in an unpacking program a shell reads back: the list of the pack's bytes, and the
      # two variables set when it gets to its end and when something went wrong
      # (Original::Unpacking).
      UnpackingNames = Data.define(:bytes, :finished, :fault_kind)

      # A file a player picked that is not a copy the game reads, or one whose unpacking went wrong.
      class Refused < StandardError; end

      # +game+, +menu+ and each of +unpackings+ (by the release's name) are the three programs as
      # Ruby (Backends::Ruby#live_source), each made a LiveGame afresh every time it plays.
      # +releases+ is the Original::Releases a picked file must be one of, and +start_file+ the
      # game's IR::StartFile, which a kept pack must pass. A pack is +before_sha1+, the copy's SHA-1,
      # +after_sha1+ and what the unpacking wrote. +menu_choice+ and +choices+ are the menu's
      # variable and what each number in it means ({ 1 => :load_rom, 2 => :settings }), and +folder+
      # the name of the folder the pack is kept in.
      def initialize(title:, game:, menu:, unpackings:, releases:, start_file:, before_sha1:, after_sha1:, names:,
                     menu_choice:, choices:, folder:)
        @title = title
        @game = game
        @menu = menu
        @unpackings = unpackings
        @releases = releases
        @start_file = start_file
        @before_sha1 = before_sha1.b
        @after_sha1 = after_sha1.b
        @names = names
        @menu_choice = menu_choice.to_s
        @choices = choices
        @folder = folder
      end

      # The name of the folder the pack is kept in (Original::Shell.folder_name), and of its file.
      attr_reader :folder

      PACK_FILE = "data.pack"

      # The Live::Shell for +shell+, an Original::Shell, its programs written as Ruby here.
      def self.from(shell)
        ruby = IR::Backends::Ruby.new
        new(title: shell.title, game: ruby.live_source(shell.game), menu: ruby.live_source(shell.menu),
            unpackings: shell.unpackings.transform_values { |unpacking| ruby.live_source(unpacking.program) },
            releases: shell.releases, start_file: shell.pack_form.start_file, before_sha1: shell.pack_form.before_sha1,
            after_sha1: shell.pack_form.after_sha1, folder: shell.folder,
            names: UnpackingNames.new(bytes: Original::Unpacking::BYTES.to_s, finished: Original::Unpacking::FINISHED.to_s,
                                      fault_kind: Original::Unpacking::FAULT_KIND.to_s),
            menu_choice: Original::Shell::MENU_CHOICE,
            choices: { Original::Shell::LOAD_ROM => :load_rom, Original::Shell::SETTINGS => :settings })
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

        unpacking = IR::Backends::Ruby::LiveGame.new(@unpackings.fetch(@releases.with_sha1(sha1).name)).hand_file(bytes)
        rate = Session.new(game: unpacking, uncapped: true, keep_last_picture: false).play(device)
        return nil unless rate.stopped_itself?

        state = unpacking.state
        unless state.vars.fetch(@names.finished) == 1 && state.vars.fetch(@names.fault_kind).zero?
          raise Refused, "#{named} is a copy this game reads, and its unpacking stopped part way (fault " \
                         "#{state.vars.fetch(@names.fault_kind)}). This is a fault in the game. Tell its makers."
        end

        [@before_sha1, [sha1].pack("H*"), @after_sha1, state.lists.fetch(@names.bytes).map { |item| item & 0xFF }.pack("C*")].join.b
      end

      private

      # The pack kept in +folder_path+ when it is one this shell reads, else nil; a file there that is
      # not one is said to +refused+ (the menu then asks for the copy again).
      def kept_pack(folder_path, refused)
        path = File.join(folder_path, PACK_FILE)
        return nil unless File.file?(path)

        bytes = File.binread(path)
        refusal = @start_file.refusal(bytes)
        return bytes unless refusal

        refused.call("#{path}: #{refusal} Load your copy of #{@title} again to make it.")
        nil
      end

      # Which line the player chose on the menu (+choices+' meaning), or nil when the device stopped it.
      def play_menu(device)
        menu = IR::Backends::Ruby::LiveGame.new(@menu)
        rate = Session.new(game: menu, keep_last_picture: false).play(device)
        return nil unless rate.stopped_itself?

        @choices[menu.state.vars.fetch(@menu_choice)]
      end

      # The pack made from the file +choose_copy+ picks and written to +folder_path+, or nil when
      # nothing was picked, the file was refused, or the device stopped the unpacking.
      def load_copy(device, folder_path, choose_copy, refused)
        path = choose_copy.call or return nil
        pack = pack_from_copy(path, File.binread(path), device) or return nil
        write_pack(folder_path, pack)
        pack
      rescue Refused, SystemCallError => e
        refused.call(e.message)
        nil
      end

      # Written to a file beside it and then moved into place, so a pack is never left half written.
      def write_pack(folder_path, pack)
        FileUtils.mkdir_p(folder_path)
        path = File.join(folder_path, PACK_FILE)
        File.binwrite("#{path}.writing", pack)
        File.rename("#{path}.writing", path)
      end
    end
  end
end
