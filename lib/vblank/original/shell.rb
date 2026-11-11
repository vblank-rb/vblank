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
    # - +menu+, what shows while there is no pack: the game's title, LOAD ROM and SETTINGS (#menu_program),
    #   handed the line its cursor starts on as its start file;
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
      Part = Data.define(:role, :number, :program, :window_menu) do
        # A shell saves only its game, once the shell has handed over to it: the menu and the unpackings
        # run before that, and a state is never taken or loaded while they do. The game part's states are
        # its own, checked against its own build.
        def keeps_states? = role == :game && window_menu
      end

      # The game first, then the menu, then each unpacking in the order of its number.
      def parts
        [Part.new(role: :game, number: nil, program: game, window_menu: window_menu),
         Part.new(role: :menu, number: nil, program: menu, window_menu: true),
         *unpackings.each_with_index.map { |unpacking, number| unpacking_part(unpacking, number) }]
      end

      private def unpacking_part(unpacking, number)
        Part.new(role: :unpacking, number: number, program: unpacking.program, window_menu: false)
      end

      # The variable the menu sets as it halts, and what each number means. A line a game adds one
      # day takes a number after these two, which never change.
      MENU_CHOICE = :shell_choice
      LOAD_ROM = 1
      SETTINGS = 2

      # The variable holding the line under the cursor, from 0, which a runtime reads as the menu
      # halts and hands back as the menu's start file when it plays the menu again.
      MENU_LINE = :shell_line

      # The menu's start file (ShellFacts.menu_start_file): the line the cursor starts on, then 1
      # when the pack kept in the game's folder is one this build does not read, else 0.
      MENU_START = :shell_start
      MENU_START_TITLE = "menu line"
      MENU_START_BYTES = 2

      # Where the menu says the game's data must be read again: this many rows under its last
      # line, this many rows between one row of its words and the next, and this much room left
      # at each side.
      READ_AGAIN_GAP = 8
      READ_AGAIN_ROW_GAP = 3
      READ_AGAIN_MARGIN = 8

      # The variable holding which of the game's own scenes is up in the menu's place, from 1; 0
      # while the menu is.
      MENU_SCENE = :shell_scene

      # The menu's routine that draws its picture.
      MENU_PICTURE = :shell_menu_picture

      # How many frames the chosen line shows as chosen before the menu halts: long enough to see,
      # short enough that the file chooser seems to open at once.
      CHOSEN_FRAMES = 8

      # The shell of +game+ (a Cartridge::Game), built for +console+: the game with its pack left out
      # and the rest as the top of this class has it. Built with every copy of every original hidden
      # (Original.without_copies), so a port whose code needs the copy to be made stops here, naming
      # the line that asked for it.
      def self.build(game, console: game.consoles.first, settings: {}, err: $stderr, progress: Messages::Progress.silent)
        Original.without_copies do
          parts = game.shell_parts(console: console, settings: settings, err: err, progress: progress)
          program = parts.program
          data_pack = parts.data_pack
          refuse_without_data_pack!(game, data_pack)
          releases = refuse_unusable_releases!(data_pack.original)
          # The first screen is made with the copies still hidden: its block is the game's code too.
          new(game: program, menu: menu_program(game.title, program, releases.title, parts.first_screen),
              unpackings: releases.readable.map { |release| data_pack.unpacking(release: release) },
              facts: facts_of(game.title, program, data_pack, releases), window_menu: game.menu?,
              original: data_pack.original)
        end
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
                                    unpacking: numbers[release.name],
                                    files: release.files&.map { |file| ShellFacts.plain_record(file) })
          end,
          release_words: releases.words,
          pack_before_sha1: header.byteslice(0, Pack::SHA1_AT).b, pack_after_sha1: header.byteslice(Pack::BUILD_VERSION_AT..).b,
          pack_rules: program.start_file.rules,
          menu: ShellFacts::Menu.new(choice_variable: MENU_CHOICE.to_s, load_rom: LOAD_ROM, settings: SETTINGS,
                                     line_variable: MENU_LINE.to_s),
          unpacking: ShellFacts::UnpackingNames.new(bytes: Unpacking::BYTES.to_s, finished: Unpacking::FINISHED.to_s,
                                                    fault_kind: Unpacking::FAULT_KIND.to_s),
          words: ShellFacts.words_for(releases.title.to_s)
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

      # The words of the two lines every first screen has, and of the line saying what the game
      # needs, where a game gives none of its own.
      MENU_LINES = ["LOAD ROM", "SETTINGS"].freeze
      MENU_NEEDS = "LOAD YOUR COPY OF THE GAME"

      # One line of the menu: its +words+, the +number+ MENU_CHOICE is set to when it is chosen
      # (LOAD_ROM, SETTINGS, then 3 and up for a game's own lines in the order written, whatever
      # place each has on the screen), the +scene+ it shows and comes back from (nil for the two
      # lines a runtime acts on), and the line of the game that wrote it (+source+, nil for those two).
      MenuLine = Data.define(:words, :number, :scene, :source)

      # How a first screen looks: its +font+ (a name), the +title+ and +needs+ words above the
      # lines, each part's colour (+colors+, by the names of DSL::ShellScreen::DEFAULT_COLORS),
      # the +picture+ behind the words (a DSL::ShellScreen::Picture, or nil), and its +lines+
      # (each a MenuLine), top to bottom.
      Look = Data.define(:font, :title, :needs, :colors, :picture, :lines)

      # The rows the words are written on: the +title+'s, the +needs+ line's, the first line's
      # (+first_line+), and the +step+ from one line down to the next.
      Rows = Data.define(:title, :needs, :first_line, :step)

      # THE LINES OF A FIRST SCREEN, top to bottom, for what a game +given+ (a DSL::ShellScreen):
      # LOAD ROM, the game's lines that go under it, SETTINGS, and the game's lines under that.
      # LOAD ROM and SETTINGS keep their numbers whatever is added, since three runtimes read them.
      def self.menu_lines(given)
        own = given.lines.each_with_index.map do |line, at|
          [line.under, MenuLine.new(words: line.words, number: SETTINGS + 1 + at, scene: line.shows, source: line.source)]
        end
        fixed = { load_rom: LOAD_ROM, settings: SETTINGS }
        DSL::ShellScreen::FIXED_LINES.each_with_index.flat_map do |which, at|
          words = given.label(which) || MENU_LINES.fetch(at)
          [MenuLine.new(words: words, number: fixed.fetch(which), scene: nil, source: nil),
           *own.select { |under, _| under == which }.map(&:last)]
        end
      end

      # THE MENU, a small game of the library's own built for the console +game+ (the game's
      # program) is built for: the title, a line naming what the game needs, and lines picked with
      # up and down and chosen with A or Start. Game code, so each runtime plays it as it plays any game.
      #
      # A GAME MAKES IT ITS OWN with `shell_screen` (+first_screen+, what the game gave, or nil):
      # its font, colours, a picture, its words, and lines of its own (Builder::ShellScreens, whose
      # block is run on this menu's builder). A game that gives nothing gets the screen as it
      # always was. A LINE OF THE GAME'S OWN SHOWS A SCENE AND COMES BACK, all inside this
      # program: chosen, it shows as chosen as any line does, then its scene is called every pass
      # over the ground's colour until A, B or Start is pressed, and the menu is back with the
      # cursor where it was. The menu does not halt for it, so no runtime hears of such a line.
      #
      # THE LINE CHOSEN SHOWS AS CHOSEN, in yellow, for CHOSEN_FRAMES frames in which no button
      # does anything. Then the menu sets MENU_CHOICE and halts, and the runtime does what was
      # chosen with that picture still up, so a file chooser opens over a menu that shows what
      # the player did.
      #
      # THE CURSOR STARTS WHERE THE RUNTIME PUTS IT. The menu ends each time a line is chosen, and
      # plays again from its start when a chooser is closed with nothing picked, a file is refused or
      # the settings are shut. So the line under the cursor (MENU_LINE) is read as it halts and
      # handed back as its start file, one byte, and the menu comes back as it was left. A game
      # is handed its data pack the same way (IR::StartFile), so every runtime has the means already.
      #
      # A PACK KEPT BY AN OLDER BUILD IS SAID HERE, AND NOWHERE ELSE. A port grows a part at a time,
      # and each part changes its pack, so a player who takes a new build finds the pack the old
      # one kept. Nothing went wrong and the player did nothing: the copy is read again, as on the
      # first start. So the runtime says only that such a pack is there (the start file's second
      # byte), and the menu says under its lines, in the words of #read_again_rows, that the
      # data must be read again from the player's copy of +original_title+, the original's own
      # title: what the player owns, where +title+ is this program's.
      def self.menu_program(title, game, original_title, first_screen = nil)
        options = Cartridge::Options.new(console: game.console, variant: game.variant, for_computer: true)
        sentence = read_again_sentence(original_title).upcase.gsub(MENU_LETTERS, "")
        Builder.keeping_builder_in_use do
          maker = Builder.new(options: options)
          maker.program.start_file = IR::StartFile.new(called: MENU_START_TITLE, size: MENU_START_BYTES, checks: [])
          maker.instance_eval do
            screen :bitmap
            look = shell_screen_look(title, first_screen)
            lines = look.lines
            rows = shell_screen_rows(text_height(font: look.font))
            shown = lines.select(&:scene) # the lines that show a scene; a scene's number is its place here, from 1
            start = table MENU_START, DSL::StartFileEntries.new(at: 0, count: MENU_START_BYTES), width: :byte, signed: false
            line = var MENU_LINE, 0
            choice = var MENU_CHOICE, 0
            chosen_for = var :shell_chosen_for, 0 # frames the chosen line has shown as chosen; 0 while none is
            scene_up = (var MENU_SCENE, 0 unless shown.empty?) # the scene showing in the menu's place; 0 while none is
            line.store!(start[0].clamp(0, lines.length - 1))
            # What the menu says of a pack to read again is VBlank's own sentence, so it is
            # written in the screen's font only where that font has every letter of it.
            said_in = IR::FontTable.of(program).get(look.font).missing_characters(sentence).empty? ? look.font : :default
            read_again = Shell.read_again_rows(sentence, screen_width - (2 * READ_AGAIN_MARGIN)) { |words| text_width(words, font: said_in) }
            func(MENU_PICTURE) do
              clear_screen look.colors.fetch(:ground)
              blit look.picture.name, look.picture.x, look.picture.y if look.picture
              draw_text look.title, :center, rows.title, look.colors.fetch(:title), font: look.font unless look.title.empty?
              draw_text look.needs, :center, rows.needs, look.colors.fetch(:needs), font: look.font unless look.needs.empty?
              lines.each_with_index do |menu_line, place|
                row = rows.first_line + (rows.step * place)
                draw_text menu_line.words, :center, row, look.colors.values_at(:line, :cursor), showing: line == place, font: look.font
                ((chosen_for > 0) & (line == place)).record_branch do
                  draw_text menu_line.words, :center, row, look.colors.fetch(:chosen), font: look.font
                end
              end
              (start[1] != 0).record_branch do
                top = rows.first_line + (rows.step * (lines.length - 1)) + text_height(font: look.font) + READ_AGAIN_GAP
                step = text_height(font: said_in) + READ_AGAIN_ROW_GAP
                read_again.each_with_index do |words, row|
                  draw_text words, :center, top + (step * row), look.colors.fetch(:needs), font: said_in
                end
              end
            end
            # The menu's own pass: its picture, the line chosen shown as chosen for a while and
            # then acted on, and otherwise the buttons.
            play_menu = lambda do
              call MENU_PICTURE
              (chosen_for > 0).record_branch do
                chosen_for.store!(chosen_for + 1)
                (chosen_for > CHOSEN_FRAMES).record_branch do
                  lines.each_with_index do |menu_line, place|
                    (line == place).record_branch do
                      if menu_line.scene
                        chosen_for.store!(0)
                        scene_up.store!(shown.index(menu_line) + 1)
                      else
                        choice.store!(menu_line.number)
                        halt
                      end
                    end
                  end
                end
              end.else do
                pressed(:down).record_branch { line.store!((line + 1) % lines.length) }
                pressed(:up).record_branch { line.store!((line + lines.length - 1) % lines.length) }
                %i[a start].each { |button| pressed(button).record_branch { chosen_for.store!(1) } }
              end
            end
            # Drawn before the loop's first wait too, so the menu's first picture is the menu and a
            # menu played again shows no empty frame between its last picture and its first.
            call MENU_PICTURE
            game_loop do
              if shown.empty?
                play_menu.call
              else
                # A scene of the game's own, up in the menu's place: the ground, then the scene's
                # own drawing, each pass until a button sends the player back.
                (scene_up > 0).record_branch do
                  clear_screen look.colors.fetch(:ground)
                  case_var(MENU_SCENE) { shown.each_with_index { |menu_line, at| when_val at + 1, menu_line.scene } }
                  %i[a b start].each { |button| pressed(button).record_branch { scene_up.store!(0) } }
                end.else { play_menu.call }
              end
            end
            finalize_program
          end
          maker.program
        end
      end

      # What the menu says when the pack kept in the game's folder is one this build does not
      # read: what happened, then what to do, naming the original the player owns.
      def self.read_again_sentence(original_title)
        "This version must read the game's data again. Load your copy of #{original_title}."
      end

      # +sentence+ cut into rows of words, each no wider than +width+ by the block's measure of a
      # row's words (a word wider than that has a row to itself).
      def self.read_again_rows(sentence, width)
        sentence.split.each_with_object([]) do |word, rows|
          if rows.any? && yield("#{rows.last} #{word}") <= width
            rows[-1] = "#{rows.last} #{word}"
          else
            rows << word
          end
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
