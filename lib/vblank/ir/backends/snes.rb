# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # Raised when a program cannot be made into a Super Nintendo cartridge: it reaches something
        # the Super Nintendo cannot do, or something its build does not make yet, or it is too big
        # for the cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "snes/w65816"
require_relative "snes/gsu"
require_relative "snes/spc700"
require_relative "snes/linker"
require_relative "snes/memory"
require_relative "snes/samples"
require_relative "snes/dsp_writes"
require_relative "snes/music"
require_relative "snes/text_layer_art"
require_relative "snes/runtime"
require_relative "snes/chip_code"
require_relative "snes/art"
require_relative "snes/painted_art"
require_relative "snes/row_bands"
require_relative "snes/lowering/picture"
require_relative "snes/lowering/paint"
require_relative "snes/lowering/collision"
require_relative "snes/lowering/saving"
require_relative "snes/lowering/sound"
require_relative "snes/lowering/chip"
require_relative "snes/lowering"
require_relative "snes/headless_run"
require_relative "snes/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a SUPER NINTENDO cartridge: the same program every other backend runs, lowered
      # to the 65816, the console's 16-bit processor, and laid out in a LoROM cartridge.
      #
      # HOW IT IS MADE. SNES::Lowering walks the IR and emits 65816 machine code through the Ruby
      # assembler (SNES::W65816), as the Game Boy Color's lowering emits SM83, and shares with
      # that lowering what both work out before writing an instruction (LoweringPlan, RoutineCuts,
      # Sections). The runtime the code calls is written in 65816 here, in Ruby.
      #
      # THE BOARD. A plain cartridge is ROM alone, with battery-backed RAM when the game saves, and
      # runs on a plain console. A game that names the Super FX 2 (`variants: { snes: :superfx }`)
      # gets that chip's board instead (Cartridge::SNESROM::SUPER_FX): the same 65816 code, read at
      # the slow speed, with the chip's registers and RAM beside it, and the routines the game marks
      # `on_chip: true` lowered to the chip's own code (ChipCode). The SA-1 and the MSU-1 are not made.
      class SNES
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says: every
        # variable by the game's name (its address in work RAM), every list ([its 24-bit place, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, the program it was built
        # from, each entry of the interpreter's sound log by the number the cartridge's own log keeps
        # it as (empty for a game that makes no sound), what the DSP writes for those entries are
        # worked out with (DSPWrites::Voicing, Lowering::Sound#sound_voicing), and the game's
        # recordings by the number a place playing one keeps (Runtime::Recordings), and each sprite
        # picture's number as SpriteNames numbers the picture it shows (Lowering::Picture#sprite_picture_names).
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines, :sound_entries,
                             :sound_voicing, :recording_names, :sprite_picture_names, :console_voice_bits) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them
          # (Reference#sprites): what the runtime keeps of what it placed (Runtime::Picture::DRAWN).
          # +drawn+ is the program's SpriteNames; +read16+ reads a word of the running cartridge's
          # memory, given its address. A picture copied in other colours is named as the picture
          # it copies.
          def drawn_sprite_rows(drawn, read16)
            at = runtime.fetch(Runtime::Picture::DRAWN)
            signed = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            Array.new(read16.call(at)) do |i|
              whose, picture, x, y = Array.new(4) { |word| read16.call(at + 2 + (i * Runtime::Picture::DRAWN_BYTES) + (word * 2)) }
              drawn.row(signed.call(whose), sprite_picture_names.fetch(picture, picture), signed.call(x), signed.call(y))
            end
          end
        end

        # One routine of the game's in the cartridge: the addresses its code takes, 24 bits each,
        # and what it is to the author.
        GameRoutine = Data.define(:addresses, :routine)

        # What the build found to say about what it decided (Cartridge::LoweredBuild).
        def findings = (@findings ||= [])

        def small_pieces_finding
          Guardrails::Finding.new(
            check: :snes_small_sprite_pieces, severity: :warning, node: :program,
            message: "The sprites have too many different tiles to keep their squares of 16×16, so this " \
                     "game is built from pieces of 8×8. Each sprite now takes more rows of the sprite table " \
                     "of #{Runtime::Picture::MOST_SPRITES}, and a sprite past the last row is not drawn. To " \
                     "fix this, use fewer different pictures."
          )
        end

        # +program+ as a cartridge (Cartridge::SNESROM), carrying its Places.
        #
        # A sprite's squares of 16×16 keep their four tiles together, so they share fewer than 8×8
        # pieces do and a game that only just fits its sprite tiles can run out. It is built again
        # in 8×8 pieces, which fits, and takes more of the sprite table, which it says, since a
        # game that needed the squares to fit the table has now lost sprites with no error.
        #
        # A game whose backgrounds need more than the console's eight sets of colours is built again
        # with each scene bringing its own in (+screen_colors+, and +sprite_colors+ for a game whose
        # sprites are what does not fit; Art), which a game that fits has no
        # need of and is not built with: it stays the bytes it was. A game whose sprites do not fit
        # the console's 512 tiles has each scene's in video memory while it is up (+sprite_tiles+),
        # before it gives up squares, and the same for 1024 background tiles (+background_tiles+).
        # A screen that still does not fit is cut small alone (+small_sprite_scenes+). Before any of
        # those, a game of sprites in several lists of colours is built with one set of their
        # pictures, worn in every list (+one_sprite_tile_set+): what it costs is a whole set of
        # colours for each list, so it is tried only where the sprites do not fit otherwise, and
        # given up if the lists do not fit that way.
        def build(program, title: "VBLANK", sprite_squares: true, screen_colors: false, sprite_colors: false, sprite_tiles: false,
                  background_tiles: false, small_sprite_scenes: [], one_sprite_tile_set: false)
          board = board_for(program)
          memory = Memory.new
          refuse_save_on_chip_board!(board) if SaveLayout.named_by?(program)
          carries = Runtime::Carries.of(program, board: board, screen_colors: screen_colors, sprite_colors: sprite_colors,
                                                 sprite_tiles: sprite_tiles, background_tiles: background_tiles)
          Runtime.reserve(memory, carries)
          lowering = Lowering.new(program, memory: memory, sprite_squares: sprite_squares, screen_colors: screen_colors,
                                                sprite_colors: sprite_colors, sprite_tiles: sprite_tiles,
                                                background_tiles: background_tiles, small_sprite_scenes: small_sprite_scenes,
                                                one_sprite_tile_set: one_sprite_tile_set, chip: carries.chip?)
          choices = { sprite_squares: sprite_squares, screen_colors: screen_colors, sprite_colors: sprite_colors,
                      sprite_tiles: sprite_tiles, background_tiles: background_tiles,
                      small_sprite_scenes: small_sprite_scenes, one_sprite_tile_set: one_sprite_tile_set }
          begin
            game = lowering.sections + lowering.art_sections
          rescue Art::ScreenSpritesFull => e
            built = build_with_one_sprite_tile_set(program, title, choices, lowering)
            return built if built

            return build(program, title: title, **choices, small_sprite_scenes: [*small_sprite_scenes, e.scene])
          rescue Art::TooManyBackgroundColors
            return build(program, title: title, **choices, screen_colors: true)
          rescue Art::TooManySpriteColors
            return build(program, title: title, **choices, sprite_colors: true)
          rescue Art::TooMuch => e
            built = build_with_one_sprite_tile_set(program, title, choices, lowering) if e.is_a?(Art::TooManySpriteTiles)
            return built if built

            return build(program, title: title, **choices, sprite_tiles: true) if e.is_a?(Art::TooManySpriteTiles) && lowering.sprites_of_one_scene?
            return build(program, title: title, **choices, background_tiles: true) if e.is_a?(Art::TooManyBackgroundTiles) && lowering.backgrounds_of_one_scene?
            raise unless sprite_squares

            findings << small_pieces_finding
            return build(program, title: title, **choices, sprite_squares: false)
          end
          findings.concat(lowering.sprite_table_findings)
          findings.concat(routines_without_their_chip(program)) unless carries.chip?
          runtime = Runtime.sections(memory, carries, lowering)
          linked =Linker.new(runtime + game, most_banks: board.most_banks).link
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, routines: routines,
                             sound_entries: lowering.sound_entries, sound_voicing: lowering.sound_voicing,
                             recording_names: lowering.recording_names,
                             sprite_picture_names: lowering.sprite_picture_names,
                             console_voice_bits: Music.voice_bits(DSPWrites::CONSOLE_VOICES.to_a - carries.recording_voices))
          vectors = { reset: linked.address_of("rt_reset"), nmi: linked.address_of("rt_nmi"),
                      irq: linked.address_of("rt_irq"), brk: linked.address_of("rt_irq"),
                      cop: linked.address_of("rt_irq") }
          Cartridge::SNESROM.new(linked.banks, title: title, vectors: vectors.transform_values { |at| at & 0xFFFF },
                                               built: built, board: board,
                                               save_bytes: carries.saves ? Runtime::Saving::SIZE : 0)
        end

        private

        # The game built with one set of its sprites' pictures (#build), or nil where that does not
        # apply or does not fit, which leaves the other ways of fitting it to be tried, once, and with
        # nothing the attempt found to say.
        def build_with_one_sprite_tile_set(program, title, choices, lowering)
          return nil if choices[:one_sprite_tile_set] || @one_sprite_tile_set_failed || !lowering.sprites_draw_with_lists?

          said = findings.length
          begin
            build(program, title: title, **choices, one_sprite_tile_set: true)
          rescue Art::TooMuch, Lowering::NotMadeYet
            @one_sprite_tile_set_failed = true
            findings.slice!(said..)
            nil
          end
        end

        # A board with a chip on it (a Super FX) has RAM that is the chip's: bsnes keeps all of it as
        # the save, and the painted screen takes most of it. The build does not keep a save there yet.
        def refuse_save_on_chip_board!(board)
          return if board.chip_ram_bytes.zero?

          raise LoweringError, "This game saves, and it is for a #{Console::SUPER_NINTENDO.title} with a chip on its " \
                               "cartridge. The build cannot keep a save on that cartridge yet. To fix this, remove the " \
                               "chip from variants: or from --variant, or build the game without saves for that console."
        end

        # A word that asks for a chip this cartridge does not have changes nothing, and a game much
        # too slow gives no other sign of why, so it is said once for each routine.
        def routines_without_their_chip(program)
          program.walk.select { |node| node.kind == :func && node.on_chip }.map do |routine|
            Guardrails::Finding.new(
              check: :snes_on_chip_without_chip, severity: :warning, node: routine,
              message: "The routine :#{routine.name} says `on_chip: true`, and this #{Console::SUPER_NINTENDO.title} " \
                       "cartridge has no chip. The routine runs on the console's own processor. To run it on the " \
                       "chip, add `variants: { snes: :superfx }` to the game, or build with `--variant superfx`."
            )
          end
        end

        # The board +program+'s cartridge is laid out for (Cartridge::SNESROM::BOARDS): the one its
        # variant names (Console::Variant#build), or a plain one. A variant whose board is not made
        # yet is refused.
        def board_for(program)
          variant = program.variant && Console.for(:snes).variant(program.variant)
          return Cartridge::SNESROM::PLAIN unless variant

          Cartridge::SNESROM::BOARDS.fetch(variant.build[:board]) do
            raise LoweringError, "This game is for a #{Console::SUPER_NINTENDO.title} with #{variant.title}. The " \
                                 "build cannot make a cartridge with that chip yet. To fix this, remove the chip " \
                                 "from variants: or from --variant."
          end
        end
      end
    end
  end
end
