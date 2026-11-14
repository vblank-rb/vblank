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
require_relative "snes/tile_bytes"
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
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes shows: every
        # variable by the game's name (its address in work RAM), every list ([its 24-bit place, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, the program it was built
        # from, each entry of the interpreter's sound log by the number the cartridge's own log keeps
        # it as (empty for a game that makes no sound), what the DSP writes for those entries are
        # worked out with (DSPWrites::Voicing, Lowering::Sound#sound_voicing), and the game's
        # recordings by the number a place playing one keeps (Runtime::Recordings), each sprite
        # picture's number as SpriteNames numbers the picture it shows (Lowering::Picture#sprite_picture_names),
        # and the pieces it made of each picture (Lowering::Picture#sprite_pieces_built).
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines, :sound_entries,
                             :sound_voicing, :recording_names, :sprite_picture_names, :sprite_pieces, :console_voice_bits) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter gives them
          # (Reference#sprites): what the runtime keeps of what it placed (Runtime::Picture::DRAWN).
          # +drawn+ is the program's SpriteNames; +read16+ reads a word of the running cartridge's
          # memory, given its address. A picture copied in other colours is named as the picture
          # it copies.
          def drawn_sprite_rows(drawn, &read16)
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

        # The settings of one try (#build, BuildTries), each the Lowering's setting of the same name
        # (Art says what each does), and +far_tables+ Memory's. +one_sprite_tile_set+ is false, true,
        # or :failed for a game that tried it and did not fit, which is not tried again.
        Tried = Data.define(:sprite_squares, :screen_colors, :sprite_colors, :sprite_tiles, :background_tiles,
                            :lean_square_scenes, :small_sprite_scenes, :one_sprite_tile_set, :scene_recordings,
                            :shared_held_lists, :far_tables) do
          # Everything the simple way: a game that fits so builds the bytes it always has.
          def self.first = new(sprite_squares: true, screen_colors: false, sprite_colors: false, sprite_tiles: false,
                               background_tiles: false, lean_square_scenes: {}, small_sprite_scenes: [],
                               one_sprite_tile_set: false, scene_recordings: false, shared_held_lists: false,
                               far_tables: false)
        end

        # A try that fit: the cartridge, the settings and lowering it was made with, what the
        # lowering found to say, and the sprite pieces it made of each picture.
        Fit = Data.define(:cartridge, :settings, :lowering, :findings, :sprite_pieces)

        # +sleeps_every_pass+ builds the cartridge a checked run reads, in which every pass sleeps
        # until the next blank, even one that ends inside a blank (Runtime::Frame#emit_sleep_unless_in_blank).
        # Every other build leaves it unset, and a game without music is the same bytes either way.
        def initialize(sleeps_every_pass: false)
          @sleeps_every_pass = sleeps_every_pass
        end

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
        # A BUILD IS A SERIES OF TRIES (BuildTries), each a whole lowering with one Tried, until one
        # fits; what each try finds it needs is kept for every try after it (#settings_after says
        # what each thing that does not fit changes).
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
        # A screen that still does not fit keeps a square only where it takes no more tiles than its
        # quarters (+lean_square_scenes+), then spends the tiles that leaves free on squares that take
        # more (#spare_tiles_attempt), and one that does not fit even so is cut small alone
        # (+small_sprite_scenes+); each says what it gave up (Picture#crowded_scene_findings). A try
        # finds every crowded screen before it stops (Art::ScreenSpritesFull), so a game of many takes
        # a try for each of those steps, not one for each screen. Before any of
        # those, a game of sprites in several lists of colours is built with one set of their
        # pictures, worn in every list (+one_sprite_tile_set+): what it costs is a whole set of
        # colours for each list, so it is tried only where the sprites do not fit otherwise, and
        # given up if the lists do not fit that way. A game whose backgrounds still need more than
        # eight sets with each scene's colours its own, some of them held by lists the game changes, is
        # built again with the short lists one background changes sharing a set (+shared_held_lists+,
        # Art): a background from the data pack of four-colour tiles walks a bank of three colours each.
        #
        # A game whose recordings all together do not fit the sound unit's memory, some of them
        # played by one scene alone, is built again with each scene sending its own across as it
        # takes over (+scene_recordings+, Runtime::Sound, "Each scene's recordings").
        #
        # A game whose runtime and variables do not fit the first 8K of work RAM, even with the
        # variables it names least past it (Lowering#place_variables), is built again with the
        # runtime's tables past it too (+far_tables+, Memory#reserve_table).
        #
        # What every try works out from the program alone is worked out once, in +cache+
        # (BuildCache), made for this build and handed to each try.
        def build(program, title: "VBLANK", cache: BuildCache.for(SNES, program))
          @build_tries = BuildTries.new(Lowering::CONSOLE.title, Tried.first)
          fit = @build_tries.run(next_settings: ->(error, try) { settings_after(error, try) },
                                 better: ->(try, fitted) { spare_tiles_attempt(try.settings, fitted.lowering) }) do |try|
            build_try(program, title, try, cache)
          end
          findings << small_pieces_finding unless fit.settings.sprite_squares
          findings.concat(fit.findings)
          program.record_sprite_pieces_built(Lowering::CONSOLE.name, fit.sprite_pieces)
          fit.cartridge
        end

        # How many times the last #build lowered the game: one for a game that fits as it first tries.
        def tries = @build_tries&.count || 0

        # THE SPRITE PIECES THE BUILD MAKES OF EACH PICTURE OF +program+ (SpriteLines.pieces_built,
        # Lowering::Picture#sprite_pieces_built), which can differ from the console's rule for
        # cutting a picture wherever the build gives up squares: worked out by building the game,
        # or nil where it cannot be built. A build records them on the program as it finishes
        # (Program#record_sprite_pieces_built), so where the cartridge has been built already
        # nothing asks here.
        #
        # A program no cartridge is made of has no cartridge's pieces to match: one handed a file
        # as it starts, or one this build stops on in any way. Its build is not checked first, as a
        # cartridge's is (Cartridge::LoweredBuild), so a program the checks would refuse can stop it
        # with any error; that refusal is the cartridge build's to make, in its own words, and here
        # the console's rule stands (SpriteLines.picture_places).
        def self.sprite_pieces_built(program)
          return nil if program.start_file

          new.build(program).built.sprite_pieces
        rescue StandardError
          nil
        end

        private

        # One try of #build (BuildTries::Try), a Fit where it fits. Its lowering is the try's +made+,
        # which #settings_after reads.
        def build_try(program, title, try, cache)
          settings = try.settings
          board = board_for(program)
          memory = Memory.new(far_tables: settings.far_tables)
          carries = cache.facts.carries(board, screen_colors: settings.screen_colors, sprite_colors: settings.sprite_colors,
                                               sprite_tiles: settings.sprite_tiles, background_tiles: settings.background_tiles)
          Runtime.reserve(memory, carries)
          lowering = try.made = Lowering.new(program, memory: memory, sprite_squares: settings.sprite_squares,
                                                      screen_colors: settings.screen_colors,
                                                      sprite_colors: settings.sprite_colors, sprite_tiles: settings.sprite_tiles,
                                                      background_tiles: settings.background_tiles,
                                                      lean_square_scenes: settings.lean_square_scenes,
                                                      small_sprite_scenes: settings.small_sprite_scenes,
                                                      one_sprite_tile_set: settings.one_sprite_tile_set == true,
                                                      chip: carries.chip?, scene_recordings: settings.scene_recordings,
                                                      shared_held_lists: settings.shared_held_lists, cache: cache)
          begin
            game = lowering.sections + lowering.art_sections
          rescue StandardError
            # A screen whose sprites did not fit stops the try once every screen has been made,
            # whatever went wrong after it (Art#refuse_crowded_scenes!).
            lowering.refuse_crowded_scenes!
            raise
          end
          lowering.refuse_crowded_scenes!
          runtime = Runtime.sections(memory, carries, lowering, sleeps_every_pass: @sleeps_every_pass)
          said = [*lowering.sprite_table_findings, *lowering.crowded_scene_findings, *lowering.scene_recording_findings]
          said.concat(routines_without_their_chip(program)) unless carries.chip?
          sprite_pieces = lowering.sprite_pieces_built
          linked = Linker.new(runtime + game, most_banks: board.most_banks).link
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, routines: routines,
                             sound_entries: lowering.sound_entries, sound_voicing: lowering.sound_voicing,
                             recording_names: lowering.recording_names,
                             sprite_picture_names: lowering.sprite_picture_names, sprite_pieces: sprite_pieces,
                             console_voice_bits: Music.voice_bits(DSPWrites::CONSOLE_VOICES.to_a - carries.recording_voices))
          vectors = { reset: linked.address_of("rt_reset"), nmi: linked.address_of("rt_nmi"),
                      irq: linked.address_of("rt_irq"), brk: linked.address_of("rt_irq"),
                      cop: linked.address_of("rt_irq") }
          cartridge = Cartridge::SNESROM.new(linked.banks, title: title, vectors: vectors.transform_values { |at| at & 0xFFFF },
                                                           built: built, board: board,
                                                           save_bytes: carries.saves ? Runtime::Saving::SIZE : 0)
          Fit.new(cartridge: cartridge, settings: settings, lowering: lowering, findings: said, sprite_pieces: sprite_pieces)
        end

        # The settings of the try after +try+, which +error+ stopped (BuildTries), an Attempt, or nil
        # where nothing left to change would help.
        def settings_after(error, try)
          settings = try.settings
          lowering = try.made
          case error
          when Memory::NearFull then settings.with(far_tables: true) unless settings.far_tables
          when Runtime::Sound::TooBig
            settings.with(scene_recordings: true) unless settings.scene_recordings || !lowering.recordings_of_one_scene?
          when Art::TooManyHeldBackgroundLists then settings.with(shared_held_lists: true)
          when Art::ScreenSpritesFull
            one_sprite_tile_set_attempt(error, settings, lowering) || crowded_scenes_settings(error, settings)
          when Art::TooManyBackgroundColors then settings.with(screen_colors: true)
          when Art::TooManySpriteColors then settings.with(sprite_colors: true)
          when Art::TooMuch
            (one_sprite_tile_set_attempt(error, settings, lowering) if error.is_a?(Art::TooManySpriteTiles)) ||
              tiles_settings(error, settings, lowering)
          end
        end

        # The settings after the sprites' or the backgrounds' tiles did not fit with +settings+:
        # each scene's in video memory while it is up, where some are one scene's, and the
        # sprites' squares given up after that.
        def tiles_settings(error, settings, lowering)
          return settings.with(sprite_tiles: true) if error.is_a?(Art::TooManySpriteTiles) && lowering.sprites_of_one_scene?
          if error.is_a?(Art::TooManyBackgroundTiles) && lowering.backgrounds_of_one_scene?
            return settings.with(background_tiles: true)
          end

          settings.with(sprite_squares: false) if settings.sprite_squares
        end

        # The settings after the screens +error+ names did not fit their sprites (Art::ScreenSpritesFull):
        # each keeps only the squares that waste no tile, and one that did not fit so is cut small.
        # Nil where one of them was spending its spare tiles (#spare_tiles_attempt): that try is given
        # up, and the one before it stands.
        def crowded_scenes_settings(error, settings)
          lean = settings.lean_square_scenes
          return nil if error.scenes.any? { |scene| lean[scene]&.positive? }

          fresh = error.scenes.reject { |scene| lean.key?(scene) }
          lean_already = error.scenes.select { |scene| lean.key?(scene) }
          settings.with(lean_square_scenes: lean.merge(fresh.to_h { |scene| [scene, 0] }),
                        small_sprite_scenes: settings.small_sprite_scenes | lean_already)
        end

        # The game tried with one set of its sprites' pictures (+one_sprite_tile_set+), an Attempt, or
        # nil where that does not apply or was tried already. If it does not fit, the build carries on
        # from +settings+ as though it had not been tried, once.
        #
        # Backgrounds over their sets of colours are not given up on: as this try found them, the other
        # tries change only how the sprites are kept, so each would fail too, and the last would
        # report the sprites instead.
        def one_sprite_tile_set_attempt(error, settings, lowering)
          return nil if settings.one_sprite_tile_set || !lowering.sprites_draw_with_lists?

          failed = settings.with(one_sprite_tile_set: :failed)
          otherwise = error.is_a?(Art::ScreenSpritesFull) ? crowded_scenes_settings(error, failed) : tiles_settings(error, failed, lowering)
          BuildTries::Attempt.new(settings: settings.with(one_sprite_tile_set: true), otherwise: otherwise,
                                  given_up_on: [Art::TooMuch, Lowering::NotMadeYet], except: [Art::BackgroundColorsFull])
        end

        # One more try after +settings+ fit, with the tiles each crowded scene left free (as +lowering+
        # made it) spent on squares that waste some (Art, "A crowded screen's sprites"), an Attempt, or
        # nil where none is left free. If it does not fit, the try that fit stands. The first try keeps
        # only the squares that waste nothing, so a picture with a blank quarter, the commonest kind,
        # would lose its square there although the room was free.
        def spare_tiles_attempt(settings, lowering)
          lean = settings.lean_square_scenes
          spare = lean.select { |_, tiles| tiles.zero? }
                      .to_h { |scene, _| [scene, lowering.free_sprite_tiles(scene)] }
                      .select { |_, tiles| tiles.positive? }
          return nil if spare.empty?

          BuildTries::Attempt.new(settings: settings.with(lean_square_scenes: lean.merge(spare)), given_up_on: [Art::TooMuch])
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
