# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # Raised when a program cannot be made into a Genesis cartridge: it reaches something the
        # Genesis cannot do, or something its build does not make yet, or it is too big for the
        # cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "genesis/m68000"
require_relative "genesis/linker"
require_relative "genesis/memory"
require_relative "genesis/tile_bytes"
require_relative "genesis/tile_store"
require_relative "genesis/art"
require_relative "genesis/painted_art"
require_relative "genesis/chip_writes"
require_relative "genesis/music"
require_relative "genesis/runtime"
require_relative "genesis/lowering/picture"
require_relative "genesis/lowering/paint"
require_relative "genesis/lowering/collision"
require_relative "genesis/lowering/sound"
require_relative "genesis/lowering/division"
require_relative "genesis/lowering/products"
require_relative "genesis/lowering/tile_runs"
require_relative "genesis/lowering/pose_rooms"
require_relative "genesis/lowering/shown_sort"
require_relative "genesis/lowering/bends"
require_relative "genesis/lowering"
require_relative "genesis/headless_run"
require_relative "genesis/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a SEGA GENESIS cartridge: the same program every other backend runs, lowered to
      # the 68000, the console's processor, and laid out flat in a cartridge of up to four megabytes.
      #
      # How it is made. Genesis::Lowering walks the IR and emits 68000 machine code through the Ruby
      # assembler (Genesis::M68000), as the Super Nintendo's lowering emits 65816, and shares with
      # that lowering what both work out before writing an instruction (LoweringPlan, RoutineCuts,
      # Sections). The runtime the code calls is written in 68000 here, in Ruby. The cartridge is
      # checked in Genesis Plus GX through ruby-genesis-emulator, which `rake compile_genesis_core`
      # builds.
      class Genesis
        # Where a running cartridge keeps what a reader wants, which nothing in its bytes shows: every
        # variable by the game's name (its address in work RAM), every list ([its address, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, the program it was built from,
        # each sprite picture's number as SpriteNames numbers the picture it shows, each entry of the
        # interpreter's sound log by the number the cartridge's own log keeps it as (empty for a game that
        # makes no sound), and what the chip writes for those entries are worked out with
        # (ChipWrites::Voicing), and the game's recordings by the number the place playing one keeps
        # (Runtime::Recordings).
        # +bytes+ gives what the cartridge's sections come to, as :code (what the processor runs) and :data
        # (what it only reads), for the cost recorded in tools/emitted_baseline.json.
        # +video_tiles+ is how many tiles the game's pictures put in video memory (VideoTiles), or nil
        # for a game that draws from none.
        # +slot_places+ is where each of a pool's lists keeps its slots, as its layout placed it
        # (Backends::PoolLayout::SlotPlace, Lowering#place_pools), by list.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :sprite_picture_names, :bytes,
                             :sound_entries, :sound_voicing, :recording_names, :video_tiles, :slot_places) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # The sprites the last pass placed (Runtime::Tiles::DRAWN), as the interpreter's rows through
          # +drawn+ (SpriteNames), each word read by the block from its work RAM address; none for a game
          # with no sprites. A count word, then a row of four words for each: whose, which picture (by the
          # number sprite_picture_names maps to SpriteNames'), across and down, each signed.
          def drawn_sprite_rows(drawn)
            at = runtime[Runtime::Tiles::DRAWN] or return []
            signed = ->(address) { yield(address).then { |value| value >= 0x8000 ? value - 0x10000 : value } }
            Array.new(yield(at)) do |i|
              row = at + 2 + (i * Runtime::Tiles::DRAWN_BYTES)
              picture = yield(row + 2)
              drawn.row(signed.call(row), sprite_picture_names.fetch(picture, picture), signed.call(row + 4),
                        signed.call(row + 6))
            end
          end
        end

        # How many 8×8 tiles the game's pictures put in video memory, which the build knows and a
        # running cartridge does not show: +room+ is how many fit, +every_screen+ how many the
        # pictures every screen shows take, and +by_scene+ how many are there while each scene is up,
        # its own and those, for a game whose scenes bring their own tiles in (empty for any other).
        # The build refuses a game past the room (Art#refuse_too_many_tiles!); this is the count for
        # one that fits.
        VideoTiles = Data.define(:room, :every_screen, :by_scene) do
          # The most in video memory at once.
          def most = [every_screen, *by_scene.values].max

          def to_h = { room: room, every_screen: every_screen, by_scene: by_scene.transform_keys(&:to_s) }
        end

        # What the build found to say about what it decided (Cartridge::LoweredBuild).
        def findings = (@findings ||= [])

        # +program+ as a cartridge (Cartridge::GenesisROM), carrying its Places.
        #
        # A game whose pictures need more tiles than video memory holds at once is built again with
        # each scene's own tiles in video memory only while it is up (+scene_tiles+, Art), so what has
        # to fit is one scene's with what every screen shows. A game that fits has no need of that
        # and is not built with it: it stays the bytes it was.
        #
        # +scene_tiles+ is :backgrounds first, every sprite picture staying in video memory for the
        # whole game, since then no frame can draw a sprite from another scene's tiles
        # (Lowering::Picture#make_art_by_scene). A game whose sprite pictures do not fit beside its
        # biggest scene's backgrounds is built once more with :sprites too, each scene's sprite
        # pictures taking turns with its backgrounds.
        #
        # A game whose pictures need more than the console's four palettes is built again the same way
        # with each scene's own colours written into the palettes as it takes over (+scene_colors+,
        # Art), so what has to fit is one scene's with what every screen keeps: :backgrounds first,
        # every sprite picture's colours kept for the whole game, then :sprites, a scene's own sprite
        # pictures' colours taking turns too, then :lists, a list the game changes that only some scenes
        # draw with keeping its palette in those scenes alone, then :list_order, each picture declared
        # with a list of colours drawn from a palette of that list in its order
        # (Lowering::Picture#scene_colors_after).
        # Those palettes are written through the game's own colours in work RAM (Runtime::Tint), so such
        # a game carries that part of the runtime even if it never fades.
        #
        # A game whose lists of colours a sprite is drawn with still do not fit a palette each is built
        # again with each such sprite drawn from copies of its poses in each list's colours
        # (+remapped_lists+, Lowering::Picture#remapped?), all in one palette where their colours fit
        # one, and the steps of +scene_colors+ are tried again from the first with those copies.
        #
        # A game whose tiles still do not fit once its scenes take turns, or that has no scenes to take
        # turns, is built again with the sprite whose poses give back the most kept to one pose in video
        # memory at a time, the pose it shows copied in from the cartridge as it changes to it (+streamed+,
        # Lowering::PoseRooms), and again with another such sprite, until the tiles fit or no sprite
        # would give any back. A game that fits without it builds as it did.
        #
        # Each of those is a try of the build (BuildTries), and a later try keeps what every earlier
        # one found it needs (#settings_after). A try sure to run out of tiles stops before its code
        # is made (Lowering::Picture#refuse_tiles_past_room_early!).
        #
        # What every try works out from the program alone is worked out once, in +cache+
        # (BuildCache), made for this build and handed to each try.
        def build(program, title: "VBLANK", cache: BuildCache.for(Genesis, program))
          @build_tries = BuildTries.new(Lowering::CONSOLE.title, Tried.first)
          @build_tries.run(next_settings: ->(error, try) { settings_after(error, try) }) do |try|
            build_try(program, title, try, cache)
          end
        end

        # How many times the last #build lowered the game: one for a game that fits as it first tries.
        def tries = @build_tries&.count || 0

        # The settings of one try (#build, BuildTries): +scene_tiles+, +scene_colors+, +streamed+ and
        # +remapped_lists+, each the Lowering's setting of the same name.
        Tried = Data.define(:scene_tiles, :scene_colors, :streamed, :remapped_lists) do
          def self.first = new(scene_tiles: false, scene_colors: false, streamed: [].freeze, remapped_lists: false)
        end

        private

        # The settings of the try after +try+, which +error+ stopped (BuildTries), or nil where
        # nothing left to try would help.
        def settings_after(error, try)
          settings = try.settings
          case error
          when Art::TooManyTiles
            later = try.made.scene_tiles_after(settings.scene_tiles)
            return settings.with(scene_tiles: later) if later

            streamed = try.made.streamed_after(settings.streamed)
            settings.with(streamed: streamed) if streamed
          when Art::TooManyColors
            later = try.made.scene_colors_after(settings.scene_colors)
            return settings.with(scene_colors: later) if later

            settings.with(remapped_lists: true, scene_colors: false) if try.made.remap_helps?
          end
        end

        # One try of #build (BuildTries::Try): the cartridge where it fits. Its lowering is the
        # try's +made+, which #settings_after reads.
        def build_try(program, title, try, cache)
          scene_tiles = try.settings.scene_tiles
          scene_colors = try.settings.scene_colors
          memory = Memory.new
          picture = Lowering.picture_of(program)
          colors = scene_colors ? true : Lowering.changing_colors?(program)
          sound = Lowering::Sound.sounds?(program)
          songs = Lowering::Sound.songs?(program)
          follows_level = songs && Music.follows_level?(program)
          effects = songs ? IR::Tunes.effects(program).uniq.size : 0
          samples = Lowering::Sound.samples?(program)
          over = picture == :painted && IR::SpritesOverPicture.any?(program)
          counted = IR::Frames.counts_from_power_on?(program)
          bends = picture == :tiled && !cache.plan.row_bends.empty?
          Runtime.reserve(memory, picture: picture, colors: colors, sprites_over_picture: over, sound: sound, songs: songs, counted: counted,
                                  music_follows_level: follows_level,
                                  effects: effects, holds_music: Lowering::Sound.holds_music?(program),
                                  wobbles: Music.wobbles?(program), steps_shapes: Music.steps_shapes?(program),
                                  swells: Music.swells_under_level?(program), slides: Music.slides?(program),
                                  sides: Music.sides_under_level?(program), samples: samples, scene_tiles: scene_tiles,
                                  glides: samples && Music.glides?(program), recorded_sides: samples && IR::Tunes.recorded_pans?(program),
                                  second_pad: Runtime::Frame.reads_second_pad?(program),
                                  team_player: Runtime::Frame.reads_team_player?(program), bends: bends)
          Runtime::Frame.reserve_last_pass(memory) if cache.plan.keeps_last_pass_number?
          lowering = try.made = Lowering.new(program, memory: memory, scene_tiles: scene_tiles, scene_colors: scene_colors,
                                                      streamed: try.settings.streamed,
                                                      remapped_lists: try.settings.remapped_lists, cache: cache)
          game = lowering.sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, registers: lowering.register_count,
                                             frame_begins: lowering.frame_begins, picture: picture,
                                             columns: lowering.plane_size.first, collision: lowering.collides?, fractions: lowering.fractions?,
                                             camera: lowering.camera?, colors: colors, sound: sound,
                                             music: (lowering.music_section if songs),
                                             music_level_at: (lowering.variables[IR::Tunes::LEVEL] if follows_level),
                                             effects: effects,
                                             plays: (lowering.recordings_sections if samples),
                                             recorded_parts: lowering.recorded_parts?,
                                             backdrop: lowering.backdrop_copied?, sprites_over_picture: over,
                                             scene_tiles: scene_tiles, scene_colors: scene_colors,
                                             runs: picture == :tiled && lowering.paints_tiles?,
                                             poses: lowering.streams_poses?,
                                             blocks: picture == :tiled && lowering.writes_cell_blocks?, bends: bends,
                                             count_at: (lowering.variables.fetch(IR::Frames::COUNT) if counted))
          linked = Linker.new(runtime + game).link
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, sprite_picture_names: picture == :tiled || over ? lowering.sprite_picture_names : {},
                             bytes: byte_counts(linked), sound_entries: lowering.sound_entries,
                             sound_voicing: lowering.sound_voicing, recording_names: lowering.recording_names,
                             video_tiles: lowering.video_tiles, slot_places: lowering.slot_places)
          Cartridge::GenesisROM.new(linked.image, title: title, vectors: vectors(linked), built: built)
        end

        # How many bytes of the cartridge are code and how many are data: the sections that hold the
        # game's tables and pictures (Lowering::DATA and Lowering::ART) are data, and the rest code.
        def byte_counts(linked)
          data, code = linked.sections.values.partition { |placed| [Lowering::DATA, Lowering::ART, Music::SONGS].include?(placed.section.holds) }
          { code: code.sum { |placed| placed.section.size }, data: data.sum { |placed| placed.section.size } }
        end

        # Where each vector points: reset starts the game, the vertical blank counts the frame and
        # reads the pad, the horizontal blank does nothing, and every way the processor can fault
        # stops the game saying so. A vector not named points where reset does.
        def vectors(linked)
          faults = %i[bus_error address_error illegal zero_divide chk trapv privilege trace line_a line_f]
          { reset: linked.address_of("rt_reset"), vertical_interrupt: linked.address_of("rt_vblank_interrupt"),
            horizontal_interrupt: linked.address_of("rt_unused_interrupt") }
            .merge(faults.to_h { |fault| [fault, linked.address_of("rt_exception")] })
        end
      end
    end
  end
end
