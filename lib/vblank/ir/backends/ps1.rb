# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # Raised when a program cannot be made into a PlayStation program: it reaches something the
        # PlayStation cannot do, or something its build does not make yet, or it is too big for the
        # console's memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "ps1/r3000"
require_relative "ps1/linker"
require_relative "ps1/memory"
require_relative "ps1/face_pieces" # what the runtime cuts a face of a place into, before the runtime that cuts it
require_relative "ps1/adpcm"
require_relative "ps1/sound_memory"
require_relative "ps1/spu_writes" # what each sound is on the sound chip, before the runtime that writes it
require_relative "ps1/music" # the song table, before the player that reads it
require_relative "ps1/runtime"
require_relative "ps1/spu_tables" # the sound chip's numbers and loops a computer's build made as the PlayStation plays
require_relative "ps1/texture_memory"
require_relative "ps1/painted_art"
require_relative "ps1/lowering/paint"
require_relative "ps1/lowering/picture"
require_relative "ps1/lowering/faces"
require_relative "ps1/lowering/sound"
require_relative "ps1/lowering"
require_relative "ps1/headless_run"
require_relative "ps1/polygon_fill" # the chip's fill of a triangle, the answer key the checked run draws faces with
require_relative "ps1/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a PLAYSTATION program: the same program every other backend runs, lowered to the
      # R3000A, the console's processor, and written as a PS-X EXE, the file a PlayStation's BIOS loads
      # from a disc and an emulator or a loader on a real console takes as it is.
      #
      # HOW IT IS MADE. PS1::Lowering walks the IR and emits MIPS machine code through the Ruby assembler
      # (PS1::R3000), as the Genesis's lowering emits 68000, and shares with the other cartridge lowerings
      # what they all work out before writing an instruction (LoweringPlan, Sections). The runtime the code
      # calls is written in MIPS here, in Ruby, and calls nothing in the BIOS. The program is checked in
      # Beetle PSX through ruby-ps1-emulator, which `rake compile_ps1_core` builds.
      #
      # WHAT IT MAKES SO FAR: a game's numbers, lists, tables, routines, scenes, timers and pad, and a
      # painted screen of one page or two, with its rectangles, pictures and text (Runtime::Paint), a
      # screen drawn from tiles, its backgrounds and its sprites drawn whole by the graphics chip every
      # pass (Runtime::Tiles), and
      # the places drawn on it in 3D, each face cut by the processor and filled by the graphics chip
      # (Runtime::Faces), and its beeps, noise, waveforms, songs, sound effects and recordings on the sound chip
      # (Runtime::Sound, Runtime::Music).
      # Everything else a game draws or plays is refused by name until it is made
      # (Lowering::NOT_LOWERED_YET).
      class PS1
        # WHERE A RUNNING PROGRAM KEEPS WHAT A READER WANTS, which nothing in its bytes shows: every variable
        # by the game's name (its address in RAM), every list ([its address, its capacity, the bytes a
        # slot, its name]), where the runtime keeps how the run stands (Runtime::Frame's names), where
        # every label of the code went, and the program it was built from. +bytes+ gives what the program's
        # sections come to (ByteCounts), and +routines+ where each of the game's routines went
        # (GameRoutine), for a profile naming where a frame's time went. +sound_entries+ is every entry
        # of the interpreter's sound log by the number the program's own log keeps it as (empty for a game
        # that makes no sound), and +sound_voicing+ what the writes for those entries are worked out with
        # (SPUWrites::Voicing: the loops in the sound chip's memory, and the songs' parts), or nil.
        # +recording_names+ is the game's recordings by the number a place playing one keeps.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :bytes, :routines, :sound_entries,
                             :sound_voicing, :recording_names) do
          # Where the runtime counts the times the game has waited for the screen.
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # The sprites the last pass placed (Runtime::Tiles::DRAWN), as the interpreter's rows through
          # +drawn+ (SpriteNames), each word read by the block from its address; none on a screen with no
          # sprites of its own.
          def drawn_sprite_rows(drawn)
            at = runtime[Runtime::Tiles::DRAWN] or return []
            word = ->(address) { Int32.wrap(yield(address)) }
            Array.new(yield(at)) do |i|
              row = at + 4 + (i * Runtime::Tiles::DRAWN_BYTES)
              drawn.row(word.call(row + Runtime::Tiles::DRAWN_WHOSE), word.call(row + Runtime::Tiles::DRAWN_PICTURE),
                        word.call(row + Runtime::Tiles::DRAWN_X), word.call(row + Runtime::Tiles::DRAWN_Y))
            end
          end
        end

        # One routine of the game's in RAM: the addresses its code takes, and what it is to the author.
        GameRoutine = Data.define(:addresses, :routine)

        # What the program's sections come to: +code+, the bytes the processor runs, and +data+, the bytes
        # it only reads (the game's tables).
        ByteCounts = Data.define(:code, :data)

        # What the build found to say about what it decided (Cartridge::LoweredBuild): nothing yet.
        def findings = (@findings ||= [])

        # +program+ as a PS-X EXE (Cartridge::PS1EXE), carrying its Places.
        def build(program, title: "VBLANK", cache: BuildCache.for(PS1, program))
          memory = Memory.new
          sound = Lowering::Sound.sounds?(program)
          songs = sound && Lowering::Sound.songs?(program)
          follows_level = songs && Music.follows_level?(program)
          effects = songs ? IR::Tunes.effects(program).uniq.size : 0
          samples = sound && Lowering::Sound.samples?(program)
          Runtime.reserve(memory, faces: program.walk.any? { |node| node.kind == :fill_face }, sound: sound,
                                  songs: songs, follows_level: follows_level, effects: effects,
                                  holds_music: Lowering::Sound.holds_music?(program),
                                  notes: { wobbles: Music.wobbles?(program), steps_shapes: Music.steps_shapes?(program),
                                           swells: Music.swells_under_level?(program), slides: Music.slides?(program) },
                                  samples: samples, tiles: Lowering::Picture.tiled?(program))
          lowering = Lowering.new(program, memory: memory, cache: cache)
          game = lowering.sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, frame_begins: lowering.frame_begins,
                                             faces: lowering.fills_faces?, sound: sound, songs: songs, effects: effects,
                                             music_level_at: (lowering.variables[IR::Tunes::LEVEL] if follows_level), samples: samples,
                                             planes: lowering.plane_places)
          # Everything has its place by now, so the program goes where the places end (Memory#program_at).
          linked = Linker.new(runtime + game, origin: memory.program_at, room: memory.program_room, kept: memory.used).link
          built = Places.new(variables: lowering.variables, lists: lowering.lists.transform_values(&:to_a),
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, bytes: byte_counts(linked),
                             routines: game_routines(lowering, linked), sound_entries: lowering.sound_entries,
                             sound_voicing: (lowering.sound_voicing if lowering.sound?), recording_names: lowering.recording_names)
          Cartridge::PS1EXE.new(linked.image, title: title, entry: linked.address_of("rt_boot"), load_at: memory.program_at,
                                              built: built)
        end

        private

        def game_routines(lowering, linked)
          lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
        end

        # How many bytes of the program are code and how many are data: the sections that hold the game's
        # tables (Lowering::TABLES_HOLDING) are data, and the rest code.
        def byte_counts(linked)
          data, code = linked.sections.values.partition { |placed| placed.section.holds == Lowering::TABLES_HOLDING }
          ByteCounts.new(code: code.sum { |placed| placed.section.size }, data: data.sum { |placed| placed.section.size })
        end
      end
    end
  end
end
