# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/paint"
require_relative "runtime/tiles"
require_relative "runtime/tint"
require_relative "runtime/picture"
require_relative "runtime/collide"
require_relative "runtime/sound"
require_relative "runtime/music"
require_relative "runtime/effects"
require_relative "runtime/recordings"

module VBlank
  module IR
    module Backends
      class Genesis
        # THE RUNTIME every Genesis cartridge carries: from power-on to the game's first line (Boot),
        # the arithmetic (Int32), the frame and the buttons (Frame), the lists (Lists), and the
        # picture (Picture).
        #
        # HOW ITS ROUTINES ARE CALLED. With JSR (and they return with RTS), from anywhere in the
        # cartridge, with A5 at the middle of work RAM (Memory::BASE, which Boot sets and nothing
        # changes); with their numbers in D0, D1, D2... and their answer in D0. A routine may use every
        # data register, A0 to A4 and A6 as it likes, but never A5.
        module Runtime
          module_function

          # The runtime's own places in work RAM, asked for before the game's. A game that makes sound
          # (+sound+) keeps its log and its voices' loudness (Sound); one with songs (+songs+) their player's
          # places, as much of them as what its songs do asks for (Music), and those of its +effects+ sound
          # effects (Effects).
          # +sprites_over_picture+ for a painted screen that shows sprites over its picture (Paint).
          def reserve(memory, picture: :none, colors: false, sound: false, songs: false, music_follows_level: false, effects: 0,
                      holds_music: false, wobbles: false, steps_shapes: false, swells: false, slides: false, sides: false, samples: false,
                      sprites_over_picture: false, scene_tiles: false)
            Frame.reserve(memory)
            Picture.reserve(memory, picture: picture, colors: colors, sprites: sprites_over_picture, scene_tiles: scene_tiles)
            Sound.reserve(memory) if sound
            Recordings.reserve(memory) if samples
            return unless songs
          
            Music.reserve(memory, follows_level: music_follows_level, effects: effects, holds: holds_music, wobbles: wobbles,
                                  steps_shapes: steps_shapes, swells: swells, slides: slides, sides: sides)
          end

          # The runtime's sections: the vectors' entry points first, then everything else in one.
          # +main+ is the label of the game's main routine; +frame_begins+ the label of the game's
          # routine run at each frame boundary (its timers moving on), or nil for none.
          # +picture+ is how the game draws (Picture), :painted, :tiled or :none, which carries what it
          # draws with, and +columns+ how many cells across the planes of a tiled one are.
          # +colors+ for a game that fades, tints or recolours (Tint), and +backdrop+ for one whose backdrop is
          # copied from a list it recolours (Lowering::Picture#backdrop_copied?).
          # +camera+ for a painted screen whose game moves the window over its picture (Paint), and
          # +sprites_over_picture+ for one that shows sprites over it. +scene_tiles+ for a tiled game whose
          # scenes each bring their own tiles in as they take over (Tiles#emit_scene_tiles).
          # +fractions+ for a game that holds numbers with a fraction (Int32).
          # +collision+ for a game that asks whether two sprites' pixels touch (Collide).
          # +registers+ is how many words of the video chip's register table the game writes
          # ("rt_vdp_registers", which the lowering makes).
          # +sound+ for a game that makes sound; +music+ the section of its songs (Genesis::Music#section),
          # for a game with songs, whose player it then carries, with +music_level_at+ where it keeps its
          # music volume if it sets one, and +effects+ how many sound effects it has; +plays+ the sections of
          # its plays of recordings and the recordings themselves (Lowering::Sound#recordings_sections), for a
          # game that plays them, which then carries their count and the sound processor's program
          # (Recordings), and +recorded_parts+ when a song or effect has a part that plays one.
          # +direct_slot_sizes+ are the slot sizes, in bytes, whose lists the game reads and writes
          # directly (Lists#emit_fixed_front_access).
          def sections(memory, main:, registers:, frame_begins: nil, picture: :none, columns: 32, collision: false, fractions: false, camera: false,
                         colors: false, sound: false, music: nil, music_level_at: nil, effects: 0, plays: nil, recorded_parts: false,
                         backdrop: false, sprites_over_picture: false, scene_tiles: false, direct_slot_sizes: [])
            entry = M68000.new("runtime entry")
            Boot.emit_vectors(entry)
            asm = M68000.new("runtime")
            Boot.emit(asm, main: main, registers: registers, held_at: memory.displacement(Frame::HELD))
            Int32.emit(asm, fractions: fractions)
            Frame.emit(asm, memory, sound: sound)
            Lists.emit(asm, memory, direct_slot_sizes: direct_slot_sizes)
            Picture.emit(asm, memory, picture: picture, columns: columns, camera: camera, colors: colors, backdrop: backdrop,
                                      sprites: sprites_over_picture, scene_tiles: scene_tiles)
            Collide.emit(asm, memory) if collision
            Sound.emit(asm, memory, songs: !music.nil?, samples: !plays.nil?) if sound
            Music.emit(asm, memory, level_at: music_level_at, effects: effects, recorded: recorded_parts) if music
            Recordings.emit(asm, memory) if plays
            emit_start(asm, samples: !plays.nil?)
            emit_frame_begins(asm, frame_begins)
            [entry.section, asm.section, music, *plays].compact
          end

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place as a long, then its number as a long, and a place of
          # nought after the last), its lists' headers, the picture's start, the screen's interrupt
          # switched on.
          def emit_start(asm, samples: false)
            asm.label("rt_start")
            asm.lea(asm.abs_l("game_starts"), asm.a(0))
            asm.label("rt_start_next")
            asm.move(:l, asm.post(0), asm.d(0))
            asm.branch(:eq, "rt_start_lists")
            asm.movea(:l, asm.d(0), asm.a(1))
            asm.move(:l, asm.post(0), asm.ind(1))
            asm.bra("rt_start_next")
            asm.label("rt_start_lists")
            asm.jsr(asm.abs_l("rt_lists_start"))
            asm.jsr(asm.abs_l("rt_picture_start"))
            asm.jsr(asm.abs_l("rt_recordings_start")) if samples
            emit_interrupt_on(asm)
            asm.rts
          end

          # The screen's interrupt switched on, once, as setting up ends: the chip told to raise it, and
          # the processor to take it. The screen itself stays off until the first pass is shown.
          def emit_interrupt_on(asm)
            h = Console::GenesisHardware
            asm.move(:w, asm.imm(h::VDP_REGISTER | (h::REG_MODE2 << 8) | h::MODE2_SCREEN_OFF | h::MODE2_VBLANK_INTERRUPT),
                     asm.abs_l(h::VDP_CONTROL))
            asm.move_to_sr(asm.imm(Frame::INTERRUPTS_ON))
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            asm.jmp(asm.abs_l(routine)) if routine
            asm.rts unless routine
          end
        end
      end
    end
  end
end
