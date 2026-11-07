# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # A PORT BUILT AS A SHELL: the game's code with none of the original's data in it, and what a
    # player's machine needs to make the data pack from the player's own copy on the first run.
    #
    # Prior art is Ship of Harkinian: the program ships with no assets, and on its first run checks
    # the ROM's hash and unpacks every asset into one archive kept beside it, read on every later run.
    # Here that is three kinds of program and the facts to join them, all made when the shell is
    # built and none needing the copy:
    #
    # - +game+, the game built with its pack left out (Builder::DataPacks), which reads the pack from
    #   the file it is handed as it starts (IR::StartFile);
    # - +menu+, what shows while there is no pack: the game's title, LOAD ROM and SETTINGS (#menu_program);
    # - +unpackings+, the game's unpacking routine built for each release the game reads, in the
    #   order of their numbers (ShellFacts::Release#unpacking), each showing a progress bar as it goes;
    # - +facts+ (ShellFacts), everything else a runtime is told: the releases a picked file must be
    #   one of, by its size and its SHA-1, the pack's header and its check, the folder it is kept in,
    #   and every sentence a file is refused in.
    #
    # +window_menu+ is whether the game's window has its menu (Cartridge::Game#menu?), and
    # +original+ the Original::Game the data pack reads, named so a check on this machine can find
    # the copy a player would pick (Live::ShellCheck). No runtime is handed it.
    #
    # WHAT A RUNTIME DOES WITH IT (Live::Shell is the Ruby one). At start it reads the pack from the
    # game's folder; a pack that passes the check is handed to the game, and the copy is never read.
    # Otherwise the menu plays. LOAD ROM asks for a file, and the file is refused unless it is a
    # release the game reads; the release's unpacking plays handed the bytes that were checked, and
    # what it wrote, after the header for the file's SHA-1, is the pack, written to the folder and
    # handed to the game. SETTINGS opens the window's settings, and the menu plays again. A pack for
    # another build of the game, or in a format this build does not read, fails the check, so the
    # menu asks for the copy again.
    #
    # The pack a shell makes is the same file, byte for byte, as the one an all-in-one build makes
    # from the same copy: the same slots in the same order, the same header.
    Shell = Data.define(:game, :menu, :unpackings, :facts, :window_menu, :original)

    class Shell
      # One program of a shell, as a backend writes it out: its +role+ (:game, :menu or :unpacking),
      # its +number+ (an unpacking's, from 0; nil for the others), the +program+, and whether its
      # window has the window's menu (+window_menu+).
      Part = Data.define(:role, :number, :program, :window_menu)

      # The game first, then the menu, then each unpacking in the order of its number.
      def parts
        [Part.new(role: :game, number: nil, program: game, window_menu: window_menu),
         Part.new(role: :menu, number: nil, program: menu, window_menu: true),
         *unpackings.each_with_index.map { |unpacking, number| unpacking_part(unpacking, number) }]
      end

      private def unpacking_part(unpacking, number)
        Part.new(role: :unpacking, number: number, program: unpacking.program, window_menu: false)
      end

      # The variable the menu sets as it halts, and what each number means.
      MENU_CHOICE = :shell_choice
      LOAD_ROM = 1
      SETTINGS = 2

      # The shell of +game+ (a Cartridge::Game), built for +console+: the game with its pack left out
      # and the rest as the top of this class has it. Built with every copy of every original hidden
      # (Original.without_copies), so a port whose code needs the copy to be made stops here, naming
      # the line that asked for it.
      def self.build(game, console: game.consoles.first, settings: {}, err: $stderr, progress: Messages::Progress.silent)
        program, data_pack = Original.without_copies do
          game.shell_parts(console: console, settings: settings, err: err, progress: progress)
        end
        refuse_without_data_pack!(game, data_pack)
        releases = refuse_unusable_releases!(data_pack.original)
        new(game: program, menu: menu_program(game.title, program),
            unpackings: releases.readable.map { |release| data_pack.unpacking(copy_size: release.size, release: release.name) },
            facts: facts_of(game.title, program, data_pack, releases), window_menu: game.menu?,
            original: data_pack.original)
      rescue NotSet => e
        raise BuildError, needs_copy_message(game, e)
      end

      # The ShellFacts of a shell of the game called +title+, whose game is +program+.
      def self.facts_of(title, program, data_pack, releases)
        numbers = releases.readable.each_with_index.to_h { |release, number| [release.name, number] }
        sizes = data_pack.slots.to_h { |slot| [slot.name, slot.byte_size] }
        header = Pack.header_bytes(sha1: "0" * 40, build_version: data_pack.build_version, sizes: sizes)
        ShellFacts.new(
          title: title.to_s, folder: folder_name(title, releases), pack_file: ShellFacts::PACK_FILE,
          releases_title: releases.title.to_s,
          releases: releases.list.map do |release|
            ShellFacts::Release.new(name: release.name, sha1: release.sha1, size: release.size, read: release.read,
                                    unpacking: numbers[release.name])
          end,
          release_words: releases.words,
          pack_before_sha1: header.byteslice(0, Pack::SHA1_AT).b, pack_after_sha1: header.byteslice(Pack::BUILD_VERSION_AT..).b,
          pack_rules: program.start_file.rules,
          menu: ShellFacts::Menu.new(choice_variable: MENU_CHOICE.to_s, load_rom: LOAD_ROM, settings: SETTINGS),
          unpacking: ShellFacts::UnpackingNames.new(bytes: Unpacking::BYTES.to_s, finished: Unpacking::FINISHED.to_s,
                                                    fault_kind: Unpacking::FAULT_KIND.to_s),
          words: ShellFacts.words_for(title.to_s)
        )
      end

      # THE FOLDER THE PACK IS KEPT IN, beside the game's saves. Two VBlank games can have one title,
      # so the folder is named from the title and from the releases of the original it reads, which
      # tell one port from another; a new build of the same port keeps the same folder, finds the
      # pack an older build made there, and asks for the copy again because the pack names the
      # older build. Letters, digits and spaces stay in the title's part, as the desktop build names
      # its folders (rg_sdl.c name_save_folder).
      def self.folder_name(title, releases)
        named = title.to_s.gsub(/[^A-Za-z0-9 ]/, "_")
        named = "game" if named.empty?
        "#{named} #{Digest::SHA1.hexdigest([title, *releases.list.filter_map(&:sha1).sort].join("\n"))[0, 8]}"
      end

      # Letters the menu's font has; anything else in a title is left out of the menu.
      MENU_LETTERS = %r{[^A-Z0-9 !.:%,'?/-]}

      # THE MENU, a small game of the library's own built for the console +game+ (the game's
      # program) is built for: the title, a line naming what the game needs, and two lines picked with
      # up and down and chosen with A or Start. Choosing one sets MENU_CHOICE and halts, and the
      # runtime does what was chosen. Game code, so each runtime plays it as it plays any game.
      def self.menu_program(title, game)
        options = Cartridge::Options.new(console: game.console, variant: game.variant, for_computer: true)
        named = title.to_s.upcase.gsub(MENU_LETTERS, "").strip
        Builder.keeping_builder_in_use do
          maker = Builder.new(options: options)
          maker.instance_eval do
            screen :bitmap
            line = var :shell_line, 0
            choice = var MENU_CHOICE, 0
            middle = screen_height / 2
            game_loop do
              clear_screen :black
              draw_text named, :center, middle - 40, :white unless named.empty?
              draw_text "LOAD YOUR COPY OF THE GAME", :center, middle - 24, :gray
              draw_text "LOAD ROM", :center, middle, %i[gray white], showing: line == 0
              draw_text "SETTINGS", :center, middle + 12, %i[gray white], showing: line == 1
              if_pressed(:down) { line.store!(1 - line) }
              if_pressed(:up) { line.store!(1 - line) }
              %i[a start].each do |button|
                if_pressed(button) do
                  choice.store!(line + 1)
                  halt
                end
              end
            end
            finalize_program
          end
          maker.program
        end
      end

      def self.refuse_without_data_pack!(game, data_pack)
        return if data_pack

        raise BuildError, "#{game.title} has no data_pack, so it holds none of an original's data already. Build " \
                          "it without --shell."
      end

      # The releases a shell can check a picked file against: each one the game reads needs its
      # SHA-1, which every release read has, and its size, since an unpacking is built for one size.
      def self.refuse_unusable_releases!(original)
        unless original.is_a?(Game) && original.releases
          raise BuildError, "The data pack's from: is not an original with releases:, and a shell checks a copy by " \
                            "its SHA-1. Give data_pack from: an Original::Game with releases:, each with its sha1 and size."
        end

        releases = original.releases

        unsized = releases.readable.reject { |release| release.size.is_a?(Integer) && release.size.positive? }
        return releases if unsized.empty?

        raise BuildError, "The #{unsized.map(&:name).join(', ')} release of #{original.title} has no size. A shell " \
                          "unpacks a copy of a known size. Give each release a size."
      end

      # The words for a shell build stopped by a line that asked for the copy: that line, the first
      # outside this library.
      def self.needs_copy_message(game, error)
        library = VBlank.root.join("lib").to_s
        line = error.backtrace_locations&.find { |place| !place.path.to_s.start_with?(library) && !place.path.to_s.include?("/gems/") }
        where = line ? "#{line.path}:#{line.lineno}" : "the game"
        "#{game.title} cannot be built as a shell: #{where} reads the copy of the original as the game is built. A " \
          "shell holds none of the original's data, so the game's code must not depend on it. Read the data " \
          "through data_pack, which a shell fills on the player's machine. #{error.message}"
      end
      private_class_method :facts_of, :refuse_without_data_pack!, :refuse_unusable_releases!, :needs_copy_message
    end
  end
end
