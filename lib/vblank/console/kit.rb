# frozen_string_literal: true

require_relative "variant"

module VBlank
  module Console
    # WHICH PARTS OF THE LIBRARY SERVE EACH CONSOLE, asked of one place.
    #
    # A game is built, checked, read back and tested the same way whichever console it is for,
    # and at a handful of points the console decides how: which build makes its cartridge, which
    # kind of cartridge that is, which reader plays it back, what a verb does on it. Each of those
    # points used to ask "is it the Color?" for itself, so a console added meant finding every one
    # of them, and every one's "no" meant the Advance. Here each console has one kit naming them
    # all, and a part of the library that needs to know asks Console.for(name) and uses what it is
    # handed. A console is added by describing it and giving it a kit, here and nowhere else.
    #
    # A kit names parts and does none of their work: each is its own module's, named here and
    # asked for when a build or a reader needs it, which is long after every module is loaded.
    #
    # What every kit answers:
    #
    #   description             what a game can tell about the console (Console::Description)
    #   answers                 what each verb does on it (Console::Answers): works, or refused
    #   answers_page            those answers written out for the reader, with anything the page
    #                           says of the console's build (what the Color's does not make yet)
    #   builder                 what makes its cartridge (Cartridge::AdvanceBuild, say). It answers
    #                           build(request), the cartridge from a checked program and a
    #                           Cartridge::BuildRequest; console_settings, the names of the CONSOLE
    #                           SETTINGS it reads (build settings only some consoles have, such
    #                           as the Advance's `stack_room:`); refuse_unusable_settings!(said),
    #                           which refuses a value of one of those it cannot use; and
    #                           cartridge_for(program, title:), the cartridge for a program alone,
    #                           which is what a test plays
    #   cartridge               the kind of cartridge that is (below)
    #   reading                 the module that gives the one reader (Diagnostics::Verifier) the
    #                           questions only its way of keeping things answers, when the reader
    #                           is made over one of its cartridges (Diagnostics::AdvanceReading,
    #                           say). Every one has PALETTE (a Verifier::PaletteLayout, how its
    #                           colours are laid out) and SAVE_FILE (a Verifier::SaveFileLayout,
    #                           where its save memory ends in the emulator's file), and gives
    #                           passes and sprites(name), and a private watch_passes! the reader
    #                           calls before the first frame. A question its cartridges cannot
    #                           answer (the Advance's registers, say) is not in it, so a reader
    #                           over one of them does not have it
    #   measured_builds?        whether its build is measured by running it, which is what chooses
    #                           what goes in a quick memory, and what its cartridge reports of
    #                           packing and placement
    #   compared_side_by_side?  whether two of its cartridges can be compared side by side
    #                           (Playthroughs::Comparison, at the console's screen size): one the
    #                           reader plays whose screen is the size its description says
    #   open_core(path, save_dir:)
    #                           the emulator its cartridges play in, opened on a cartridge file
    #   save_file_extension     how that emulator names the file it keeps battery-backed RAM in
    #   open_probe(path, save_dir:)
    #                           a running cartridge as the one reader asks of one
    #   dumps_ir?               whether `vblank build --format ir` can write its games
    #   routine_lister          what lists a routine of its cartridges (`dump_func`), or nil
    #   inspector              what prints one of its cartridges' header and first instructions
    #                           (`vblank inspect`), or nil for a console with none yet
    #   words_at_any_address?   whether its processor reads a value of two or more bytes at any
    #                           address, an odd one included, and keeps it low byte first
    #
    # What every console's cartridge answers, whichever kind it is, and all a caller that has not
    # asked which console it is for can ask of one:
    #
    #   console                    the name of the console it is for (also asked of its class)
    #   buffer, size               its bytes, and how many there are
    #   header_title               the title field of its header, as the header holds it
    #   write(path)                its bytes, written to +path+
    #   built                      what the build worked out about it, or nil
    #   source_program             the checked program it was built from
    #   var_addresses              where the build put each of the game's variables
    #   profile(format:, out:, frames:, settle:, keys:, scene:, from:)
    #                              where its frames went, run in the emulator
    #
    # and its class answers header?(bytes), whether +bytes+ are a cartridge of its kind, and
    # title_field_of(bytes). Anything else one kind has (the Advance's ROM#placement, say) is
    # asked only by code that already knows which console it holds.
    class Kit
      attr_reader :description

      def initialize(description)
        @description = description
        freeze
      end

      def name = description.name
      def title = description.title
      def measured_builds? = false
      def compared_side_by_side? = false
      def inspector = nil

      # WHETHER ITS PROCESSOR READS A NUMBER OF TWO OR MORE BYTES AT ANY ADDRESS. The ARM of the
      # Advance, the 68000 of the Genesis and the MIPS of the PlayStation read two bytes only at an
      # even address and four only at a multiple of four (the ARM turns the word round, the 68000
      # and the MIPS stop), so a game for them never keeps one anywhere else, and a read anywhere
      # else is a wrong address. The Color's SM83 and the Super Nintendo's 65816 fetch a byte at a
      # time and read a word at any address, so their games keep words at odd ones, and three-byte
      # numbers besides (the 65816's long addresses). Both keep the low byte first.
      def words_at_any_address? = false

      # The emulator core its cartridges play in, opened on a cartridge file
      # (Diagnostics::Emulator), and how the file the core keeps battery-backed RAM in is named
      # beside the cartridge's own.
      def open_core(path, save_dir:) = Diagnostics::Emulator.open(path, save_dir: save_dir)
      def save_file_extension = ".sav"

      # Where the save memory is in that file for +cartridge+ (a Verifier::SaveFileLayout): the
      # reading's SAVE_FILE, unless one kind of the console's boards keeps it elsewhere.
      def save_file_of(_cartridge) = reading::SAVE_FILE

      # A running cartridge as the one reader asks of one (Diagnostics::Verifier), opened on a
      # cartridge file, and what that file is called.
      def open_probe(path, save_dir:) = Diagnostics::Emulator.probe(path, save_dir: save_dir)

      # Whether `vblank build --format ir` can write its games (IR::Dump builds the Advance's
      # cartridge, so only the Advance's).
      def dumps_ir? = false

      # What lists a routine of its cartridges (`dump_func`) through a build that goes by the kit,
      # or nil for none. The Advance's own build lists its routines itself.
      def routine_lister = nil

      # The console settings its build reads, by name, and whether +setting+ is one of them.
      def console_settings = builder.console_settings
      def console_setting?(setting) = console_settings.include?(setting)

      # The variants of this console a build can ask for (Console::Variant), by name: none, for most.
      def variants = {}

      # THE SIZES ITS BUILD CAN DRAW A SPRITE'S PIECES AT, as [width, height] in pixels, the one a
      # game gets when it names none first; nil for a console whose build draws a sprite whole. A
      # console that draws a sprite as pieces of its sprite table draws all of them one size at a
      # time, so a game names one where it names its consoles (`sprite_piece_size:`).
      def sprite_piece_sizes = nil

      # +size+, when this console's build draws pieces that size; a plain refusal when it does not.
      def refuse_unusable_sprite_piece_size!(size)
        sizes = sprite_piece_sizes
        unless sizes
          raise ArgumentError, "sprite_piece_size: names a size for the #{title}, and a #{title} draws each sprite " \
                               "whole, not in pieces. To fix this, remove :#{name} from sprite_piece_size:."
        end
        return size if sizes.include?(size)

        said = sizes.map { |w, h| "#{w}×#{h}" }
        raise ArgumentError, "sprite_piece_size: #{size.inspect} is not a size of sprite piece. A #{title} draws sprite " \
                             "pieces #{said.join(' or ')}. To fix this, use one of those, like " \
                             "`sprite_piece_size: { #{name}: #{sizes.last.inspect} }`. Or remove :#{name}, and the " \
                             "pieces are #{said.first}."
      end

      # The variant +name+ names, or nil for the console as it is (NO_VARIANT, or no name). A name
      # this console has no variant by is refused, naming the ones it has.
      def variant(name)
        return nil if name.nil? || name.to_sym == NO_VARIANT

        variants.fetch(name.to_sym) do
          known = variants.keys.map(&:inspect)
          has = known.empty? ? "It has no variants" : "Its variants are #{known.join(', ')}"
          raise ArgumentError, "The #{title} has no variant named #{name.inspect}. #{has}. To fix this, name one " \
                               "of those, or leave the variant out."
        end
      end

      # What a game can tell about this console with the variant +name+: its description, with the
      # variant's limits.
      def described_as(name) = variant(name)&.apply(description) || description
    end

    # The Game Boy Advance's.
    class AdvanceKit < Kit
      # A GAME LAID OUT FOR THE GAME BOY COLOR'S SCREEN, ON THE ADVANCE.
      #
      # A game written for the Color's 160×144 can be built for the Advance's 240×160 without a
      # second copy of it: `consoles: %i[gbc gba], variants: { gba: :color_screen }`. The Advance
      # shows the game's picture at its own size in the middle of the screen, with a border round
      # it in the 40 columns either side and the 8 rows above and below. That is what an Advance
      # does with a Color cartridge, and no whole-number scale fits 160×144 into 240×160.
      #
      # WHY A VARIANT, AND NOT A NEW SETTING. A variant is already "this console, with some of what
      # a game can tell about it changed" (Console::Variant): here the screen is the Color's size,
      # so `screen_width` and `screen_height` answer 160 and 144 in the Advance's build, the checks
      # lay the game out against that, and the interpreter plays it on a 160×144 screen. The build
      # reads `whole_screen_size` and draws the border. `vblank build --variant`, `game.program(
      # console:, variant:)` and the rest already carry a variant to every build, so nothing new is
      # plumbed through them. A game that names no variant builds the same bytes as before.
      #
      # What else changes: the border is drawn with the console's own sprites, so the game has
      # that many fewer (BORDER_SPRITES); a background held to a box is refused, since the box and
      # the border would both need the display's windows; and the desktop build plays no start-up,
      # whose logo is drawn for the whole 240×160.
      BORDER_SPRITES = 32

      COLOR_SCREEN = Ractor.make_shareable(
        Variant.new(name: :color_screen, title: "a Game Boy Color's screen in a border",
                    changes: { screen_width: COLOR.screen_width, screen_height: COLOR.screen_height,
                               sprites: ADVANCE.sprites - BORDER_SPRITES, background_box: nil,
                               plays_bios_start_up: false, whole_screen_size: ADVANCE.screen_size.freeze },
                    build: {},
                    note: "a game laid out for the Game Boy Color's 160×144 screen, shown at its own size " \
                          "in the middle of the Advance's, with a border round it")
      )

      ADVANCE_VARIANTS = Ractor.make_shareable({ color_screen: COLOR_SCREEN })

      def variants = ADVANCE_VARIANTS

      def answers = AdvanceAnswers
      def answers_page = answers.reference
      def builder = Cartridge::AdvanceBuild
      def cartridge = Cartridge::ROM
      def reading = Diagnostics::AdvanceReading
      def dumps_ir? = true
      def measured_builds? = true
      def compared_side_by_side? = true
      def inspector = Diagnostics::Inspector
    end

    # THE KIT OF A CONSOLE WHOSE LOWERING IS CHECKED BY A RUN OF ITS OWN: its cartridge is made by
    # a lowering of the console's own, and a test run plays that cartridge in the emulator and holds
    # it to the interpreter after every pass. What such a console has besides the rest:
    #
    #   lowering     the backend that lowers a program to its cartridge (IR::Backends::GBC, say),
    #                which answers build(program, title:)
    #   checked_run  the checked run that plays one of its cartridges against the interpreter
    #                (that lowering's CheckedRun), which a test run's player is made from
    #                (Testing::CartridgeCheckedPlayer)
    #
    # Its build is the one every such console shares (Cartridge::LoweredBuild), handed this kit.
    class CheckedKit < Kit
      def builder = Cartridge::LoweredBuild.new(self)
      def checked_run = lowering::CheckedRun
    end

    # The Game Boy Color's.
    class ColorKit < CheckedKit
      def answers = ColorAnswers
      def answers_page = answers.reference(not_yet: IR::Backends::GBC::Lowering::NOT_LOWERED_YET)
      def lowering = IR::Backends::GBC
      def cartridge = Cartridge::GBCROM
      def reading = Diagnostics::ColorReading
      def routine_lister = Diagnostics::SM83Listing
      def sprite_piece_sizes = GBCHardware::SPRITE_PIECE_SIZES
      def compared_side_by_side? = true
      def words_at_any_address? = true
    end

    # The Super Nintendo's. Its cartridges play in bsnes rather than libmgba, through
    # ruby-snes-emulator, which keeps battery-backed RAM in a file of its own kind.
    class SNESKit < CheckedKit
      def answers = SNESAnswers
      def answers_page = answers.reference(not_yet: IR::Backends::SNES::Lowering::NOT_LOWERED_YET)
      def lowering = IR::Backends::SNES
      def cartridge = Cartridge::SNESROM
      def reading = Diagnostics::SNESReading
      def open_core(path, save_dir:) = Diagnostics::Emulator.open_snes(path, save_dir: save_dir)
      def open_probe(path, save_dir:) = Diagnostics::SNESProbe.new(path, save_dir: save_dir)
      def save_file_extension = ".srm"
      def save_file_of(cartridge) = reading.save_file_of(cartridge.buffer)
      def compared_side_by_side? = true
      def words_at_any_address? = true
      def variants = SNES_VARIANTS
      # Its build cuts every sprite into 8×8 pieces and has no setting for bigger ones yet.
      def sprite_piece_sizes = [[8, 8]].freeze

      # THE CHIPS A CARTRIDGE CAN CARRY that more than a handful of games used. The one-game chips
      # (the Cx4 of Mega Man X2 and X3, the S-DD1, the SPC7110, the ST010 and the rest) are left out
      # on purpose, and so is the DSP-1: an emulator needs a copy of the program built into that
      # chip, which is Nintendo's, so a homebrew cartridge has no use for it.
      #
      # Each chip's cartridge is a board of its own, not a plain cartridge with a different header
      # (Cartridge::SNESROM says what a Super FX board's header holds). +build+ names the board the
      # build lays the cartridge out for, and the build refuses a variant whose +build+ names none.
      SNES_VARIANTS = Ractor.make_shareable({
        superfx: Variant.new(name: :superfx, title: "a Super FX 2 chip",
                             # Its 64K of RAM is where it draws, and where the console's processor
                             # keeps a painted screen's picture: one page of 56K, so a painted screen
                             # keeps one page there as on a plain cartridge.
                             changes: { roomier_memory_bytes: (120 + 64) * 1024 },
                             build: { board: :super_fx },
                             note: "the Super FX 2 (GSU-2), a 21 MHz processor of its own that draws into " \
                                   "the cartridge's RAM: Yoshi's Island, Doom, Star Fox 2"),
        sa1: Variant.new(name: :sa1, title: "an SA-1 chip",
                         # 128K of battery-backed RAM beside the console's work RAM.
                         changes: { roomier_memory_bytes: (120 + 128) * 1024 },
                         build: {},
                         note: "the SA-1, a 65816 at 10.74 MHz with RAM of its own: Super Mario RPG, " \
                               "Kirby Super Star, about 35 games")
      })
    end

    # The Sega Genesis's. Its cartridges play in Genesis Plus GX, through ruby-genesis-emulator,
    # which keeps no battery-backed RAM in a file of its own: a Genesis cartridge's save memory
    # is the emulator's save RAM (the lowering does not make saves yet).
    class GenesisKit < CheckedKit
      def answers = GenesisAnswers
      def answers_page = answers.reference(not_yet: IR::Backends::Genesis::Lowering::NOT_LOWERED_YET)
      def lowering = IR::Backends::Genesis
      def cartridge = Cartridge::GenesisROM
      def reading = Diagnostics::GenesisReading
      def open_core(path, save_dir:) = Diagnostics::Emulator.open_genesis(path, save_dir: save_dir)
      def open_probe(path, save_dir:) = Diagnostics::GenesisProbe.new(path, save_dir: save_dir)
      def save_file_extension = ".srm"
      # Its build cuts every sprite into 8×8 pieces and has no setting for bigger ones yet.
      def sprite_piece_sizes = [[8, 8]].freeze
    end

    # The PlayStation's. Its programs play in Beetle PSX, through ruby-ps1-emulator. A program is a PS-X
    # EXE, and a game's saves will go on a memory card (the lowering does not make saves yet).
    class PS1Kit < CheckedKit
      def answers = PS1Answers
      def answers_page = answers.reference(not_yet: IR::Backends::PS1::Lowering::NOT_LOWERED_YET)
      def lowering = IR::Backends::PS1
      def cartridge = Cartridge::PS1EXE
      def reading = Diagnostics::PS1Reading
      def open_core(path, save_dir:) = Diagnostics::Emulator.open_ps1(path, save_dir: save_dir)
      def open_probe(path, save_dir:) = Diagnostics::PS1Probe.new(path, save_dir: save_dir)
      def save_file_extension = ".srm"
    end

    KITS =Ractor.make_shareable({ gba: AdvanceKit.new(ADVANCE), gbc: ColorKit.new(COLOR),
                                   snes: SNESKit.new(SUPER_NINTENDO), genesis: GenesisKit.new(GENESIS),
                                   ps1: PS1Kit.new(PLAYSTATION) })

    # What a game can tell about each console, by name.
    DESCRIPTIONS = Ractor.make_shareable(KITS.transform_values(&:description))

    # The kit for the console named +name+ (a Symbol or a String). A name no console has is
    # refused with the names there are.
    def self.for(name)
      KITS.fetch(name&.to_sym) do
        named = name.nil? ? "No console is named" : "There is no console named #{name.inspect}"
        *most, last = KITS.keys.map(&:inspect)
        raise ArgumentError, "#{named}. The consoles are #{most.join(', ')} and #{last}."
      end
    end

    # Every console's kit.
    def self.kits = KITS.values

    # The words a refusal uses to say which consoles a game can name, from the kits, so a console
    # added is offered without a line changing here. +written+ goes before each list, as a game
    # writes it.
    def self.how_to_name_consoles(written: "")
      first, *others = kits
      more = others.map { |kit| "`#{written}%i[#{first.name} #{kit.name}]` for the #{kit.title} too" }.join(", or ")
      "`#{written}%i[#{first.name}]` for the #{first.title} alone, #{more}."
    end

    # Every console setting there is, by name: a build setting only some consoles have
    # (Kit#console_settings).
    def self.console_settings = kits.flat_map(&:console_settings).uniq

    # Of +values+ (a setting's name to its value, as a game or a build was given them), the
    # console settings that were said: the ones that are not nil.
    def self.console_settings_said(values) = values.slice(*console_settings).compact

    # A SETTING SAID FOR A CONSOLE THAT DOES NOT HAVE IT is refused, rather than dropped: the author
    # asked for something the cartridge would not have.
    #
    # +said+ is the console settings that were said, by name, to their values
    # (console_settings_said); +consoles+ the consoles the game or the build is for; +title+ the
    # game's; and +named_in+ the keyword those consoles were named with (`consoles:` for a game,
    # `console:` for a build), so the fix says where to add one. A setting is refused when none of
    # +consoles+ has it, and a value when a console that has it cannot use it.
    def self.refuse_unusable_console_settings!(said, consoles:, title:, named_in:)
      kits = consoles.map { |name| self.for(name) }
      said.each_key do |setting|
        next if kits.any? { |kit| kit.console_setting?(setting) }

        holders = self.kits.select { |kit| kit.console_setting?(setting) }.map(&:title)
        raise ArgumentError, "`#{setting}:` is set for #{title}. Only the #{holders.join(' and the ')} " \
                             "#{holders.size == 1 ? 'has' : 'have'} this setting. #{title} is for the " \
                             "#{kits.map(&:title).join(' and the ')}. To fix this, remove `#{setting}:`. Or name " \
                             "the #{holders.first} in `#{named_in}`."
      end
      kits.each { |kit| kit.builder.refuse_unusable_settings!(said.slice(*kit.console_settings)) }
    end

    # +sizes+, the size of sprite piece a game names for each of its consoles, by console
    # (`sprite_piece_size: { gbc: [8, 16] }`), with each console held as its Symbol, when every
    # console draws pieces that size (Kit#refuse_unusable_sprite_piece_size!).
    def self.refuse_unusable_sprite_piece_sizes!(sizes)
      unless sizes.is_a?(Hash)
        raise ArgumentError, "sprite_piece_size: #{sizes.inspect} does not say which console it is for. To fix this, " \
                             "name the console with the size, like `sprite_piece_size: { gbc: [8, 16] }`."
      end

      sizes.to_h { |console, size| [named(console), self.for(console).refuse_unusable_sprite_piece_size!(size)] }
    end

    # What a game can tell about the console named +name+.
    def self.described(name, variant: nil) = self.for(name).described_as(variant)

    # The console +name+ names, as the Symbol every part of the library holds it as, so a console
    # named in a String is the same console and never a name compared and missed. A name no
    # console has is refused.
    def self.named(name) = self.for(name).name
  end
end
