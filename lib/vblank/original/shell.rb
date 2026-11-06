# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # A PORT BUILT AS A SHELL: the game's code with none of the original's data in it, and what a
    # player's machine needs to make the data pack from the player's own copy on the first run.
    #
    # Prior art is Ship of Harkinian: the program ships with no assets, and on its first run checks
    # the ROM's hash and unpacks every asset into one archive kept beside it, read on every later run.
    # Here that is three programs and the facts to join them, all made when the shell is built and
    # none needing the copy:
    #
    # - +game+, the game built with its pack left out (Builder::DataPacks), which reads the pack from
    #   the file it is handed as it starts (IR::StartFile);
    # - +menu+, what shows while there is no pack: the game's title, LOAD ROM and SETTINGS (#menu_program);
    # - +unpackings+, the game's unpacking routine built for each release the game reads, by the
    #   release's name (Unpacking), which shows a progress bar as it goes.
    #
    # and +releases+ (Releases), which a picked file must be one of, by its size and its SHA-1,
    # +pack_form+ (PackForm), how a pack the unpacking wrote is made a file and how a kept file is
    # known to be this shell's, and +folder+, the name of the folder the pack is kept in.
    #
    # WHAT A RUNTIME DOES WITH IT (Live::Shell is the Ruby one). At start it reads the pack from the
    # game's folder; a pack this shell can read (PackForm#refusal is nil) is handed to the game, and
    # the copy is never read. Otherwise the menu plays. LOAD ROM asks for a file, and the file is
    # refused unless it is a release the game reads; the release's unpacking plays handed the file,
    # and its bytes, after the header PackForm makes for the file's SHA-1, are the pack, written to
    # the folder and handed to the game. A pack for another build of the game, or in a format this
    # build does not read, fails the check, so the menu asks for the copy again.
    #
    # The pack a shell makes is the same file, byte for byte, as the one an all-in-one build makes
    # from the same copy: the same slots in the same order, the same header.
    Shell = Data.define(:title, :game, :menu, :unpackings, :releases, :pack_form, :folder)

    # HOW A PACK IS A FILE, for a runtime with no library to hand: the header before the copy's SHA-1
    # (+before_sha1+) and after it (+after_sha1+), between which the 20 bytes of the SHA-1 go, then
    # the bytes the unpacking wrote; and the file's +size+ and +checks+, which tell a pack for this
    # shell from any other (the game's own IR::StartFile, whose #refusal gives the words).
    PackForm = Data.define(:before_sha1, :after_sha1, :start_file) do
      # The pack file for a copy whose SHA-1 is +sha1+ (40 hex digits), holding +bytes+.
      def file_for(sha1, bytes) = [before_sha1, [sha1].pack("H*"), after_sha1, bytes].join.b

      # Why +bytes+ (a kept file, or nil for none) is not a pack this shell reads, or nil when it is.
      def refusal(bytes) = start_file.refusal(bytes&.b)
    end

    class Shell
      # The name of the file the pack is kept in, inside the game's folder.
      PACK_FILE = "data.pack"

      # The variable the menu sets as it halts, and what each number means.
      MENU_CHOICE = :shell_choice
      LOAD_ROM = 1
      SETTINGS = 2

      # The shell of +game+ (a Cartridge::Game), built for +console+: the game with its pack left out
      # and the rest as the top of this class says. Built with every copy of every original hidden
      # (Original.without_copies), so a port whose code needs the copy to be made stops here, naming
      # the line that asked for it.
      def self.build(game, console: game.consoles.first, settings: {}, err: $stderr, progress: Messages::Progress.silent)
        program, data_pack = Original.without_copies do
          game.shell_parts(console: console, settings: settings, err: err, progress: progress)
        end
        refuse_without_data_pack!(game, data_pack)
        releases = refuse_unusable_releases!(data_pack.original)
        new(title: game.title, game: program, menu: menu_program(game.title, program),
            unpackings: releases.readable.to_h { |release| [release.name, data_pack.unpacking(copy_size: release.size)] },
            releases: releases, pack_form: pack_form_of(program, data_pack), folder: folder_name(game.title, releases))
      rescue NotSet => e
        raise BuildError, needs_copy_message(game, e)
      end

      # The pack's header around the copy's SHA-1, for +data_pack+, and the game's check of the file.
      def self.pack_form_of(program, data_pack)
        sizes = data_pack.slots.to_h { |slot| [slot.name, slot.byte_size] }
        header = Pack.header_bytes(sha1: "0" * 40, build_version: data_pack.build_version, sizes: sizes)
        PackForm.new(before_sha1: header.byteslice(0, Pack::SHA1_AT).freeze,
                     after_sha1: header.byteslice(Pack::BUILD_VERSION_AT..).freeze, start_file: program.start_file)
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
      # program) is built for: the title, a line saying what the game needs, and two lines picked with
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
      private_class_method :pack_form_of, :refuse_without_data_pack!, :refuse_unusable_releases!, :needs_copy_message
    end
  end
end
