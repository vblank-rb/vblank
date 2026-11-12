# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/draw_list"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/pads"
require_relative "runtime/lists"
require_relative "runtime/paint"
require_relative "runtime/tiles"
require_relative "runtime/colors"
require_relative "runtime/collide"
require_relative "runtime/faces"
require_relative "runtime/sound"
require_relative "runtime/music"
require_relative "runtime/recordings"

module VBlank
  module IR
    module Backends
      class PS1
        # THE RUNTIME every PlayStation program carries: from power-on to the game's first line (Boot),
        # the arithmetic too long to write in place (Int32), the frame, the interrupt and the pads
        # (Frame, Pads), the lists (Lists), the list of drawing commands the DMA hands to the graphics chip
        # (DrawList), the painted screen (Paint), the faces of a place (Faces), and
        # the sound chip (Sound).
        #
        # HOW ITS ROUTINES ARE CALLED. With JAL, from anywhere in the program, and they return with
        # `jr ra`. Their numbers are in ARGUMENTS (a0, a1, a2, a3, then t4 to t7) and their answer in v0.
        # A routine may change at, v0, v1, the argument registers and t0 to t9, and keeps s0 to s7, gp
        # and sp as it found them; one that calls another keeps its own return address on the stack.
        # gp points into the region the game keeps its numbers in (Memory::BASE), fp at the scratchpad
        # (Memory::SCRATCHPAD_FIRST), and nothing changes either; k0 and k1 are the interrupt's.
        module Runtime
          ARGUMENTS = %i[a0 a1 a2 a3 t4 t5 t6 t7].freeze

          module_function

          # The runtime's own places in RAM, asked for before the game's; Faces's only for a game that
          # fills faces (+faces+), Sound's for one that makes sound (+sound+), and Music's for one with songs
          # (+songs+): as much of them as its songs ask for, by whether it sets the music volume
          # (+follows_level+), how many sound +effects+ it has, whether it holds its tune (+holds_music+), and
          # what its notes do as they play (+notes+, Music.reserve's wobbles:, steps_shapes:, swells:, slides:);
          # and Recordings' for one that plays recordings (+samples+); and Tiles' for one whose screen is
          # drawn from tiles (+tiles+), and Colors' for one whose colours change as it runs (+colors+); and
          # Paint's for a painted screen drawn by number (+by_number+, PS1::PaintedNumbers) or with sprites over
          # it (+over_picture+), each shown from pages of its own.
          def reserve(memory, faces:, sound: false, songs: false, follows_level: false, effects: 0, holds_music: false, notes: {}, samples: false,
                      tiles: false, colors: false, by_number: false, over_picture: false)
            Faces.reserve(memory) if faces
            Frame.reserve(memory)
            Paint.reserve(memory, shown_apart: by_number || over_picture)
            Tiles.reserve(memory) if tiles
            Tiles.reserve_sprites(memory) if over_picture
            Colors.reserve(memory) if colors
            Sound.reserve(memory) if sound
            Recordings.reserve(memory) if samples
            Music.reserve(memory, follows_level: follows_level, effects: effects, holds: holds_music, **notes) if songs
          end

          # The runtime's sections: the entry point, then everything else. +main+ is the label of the
          # game's main routine; +frame_begins+ the label of the game's routine run at each frame
          # boundary (its timers moving on), or nil for none. +faces+ is whether the game fills the
          # faces of a place, so carries Faces and its table; +sound+ whether it makes sound, so carries
          # Sound, its loops in sound memory first copied there (the game's section "sound_memory"); +songs+
          # whether it plays songs, so carries Music, with its +effects+ and the address of its music volume
          # (+music_level_at+) if it sets one; +samples+ whether it plays recordings, so carries Recordings,
          # which reads the game's table "recording_plays". +tiled+ is, for a game whose screen is drawn
          # from tiles, what Tiles draws it with (Tiles::Screen), and nil for any other, and +colors+ whether
          # its colours change as it runs, so carries Colors, which reads the game's tables of colours;
          # +collides+ whether it asks whether two sprites' pixels touch, so carries Collide; +by_number+ whether its
          # painted screen is drawn by number (PS1::PaintedNumbers), so is copied onto the screen as each pass ends;
          # +over_picture+ whether it shows sprites over its painted screen, so is copied onto the screen as each
          # pass ends and has the pass's sprites drawn over the copy.
          def sections(memory, main:, frame_begins: nil, faces: false, sound: false, songs: false, effects: 0, music_level_at: nil,
                       samples: false, tiled: nil, colors: false, collides: false, by_number: false, over_picture: false)
            asm = R3000.new("runtime")
            Faces.reserve_pieces(memory) if faces
            DrawList.reserve_late(memory)
            shown_by = Paint.shown_by(by_number: by_number, over_picture: over_picture)
            Boot.emit(asm, memory, main: main)
            DrawList.emit(asm, memory, faces: faces)
            Int32.emit(asm)
            Frame.emit(asm, memory, sound: sound, tiles: !tiled.nil?, shown_by: shown_by)
            Pads.emit(asm, memory)
            Lists.emit(asm, memory)
            Paint.emit(asm, memory, faces: faces, shown_by: shown_by)
            Tiles.emit(asm, memory, screen: tiled, faces: faces, colors: colors) if tiled
            Tiles.emit_sprite_places(asm, memory) if over_picture
            Colors.emit(asm, memory, backdrop: !tiled.nil?) if colors
            Collide.emit(asm) if collides
            Faces.emit(asm, memory) if faces
            Sound.emit(asm, memory, songs: songs, samples: samples) if sound
            Recordings.emit(asm, memory) if samples
            Music.emit(asm, memory, level_at: music_level_at, effects: effects) if songs
            emit_start(asm, sound: sound, tiles: !tiled.nil?)
            emit_frame_begins(asm, frame_begins)
            [asm.section, *(Faces.reciprocals_section(Lowering::TABLES_HOLDING) if faces)]
          end

          # The runtime place +name+, as the distance from gp an instruction names. The runtime's places
          # are reserved first, so every one is within reach of gp.
          def at(memory, name) = Memory.distance_from_base(memory[name]) || raise(LoweringError, "#{name} is out of gp's reach")

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place, then its number, a word each, and a place of nought after
          # the last), its lists' headers, its pictures in video RAM, its loops in sound memory (+sound+),
          # and the whole screen to draw on, two pages of it for a screen drawn from tiles (+tiles+).
          def emit_start(asm, sound: false, tiles: false)
            asm.label("rt_start")
            asm.addiu(:sp, :sp, -4)
            asm.sw(:ra, 0, :sp)
            asm.la(:t0, "game_starts")
            asm.label("rt_start_next")
            asm.lw(:t1, 0, :t0)
            asm.beq(:t1, :zero, "rt_start_lists")
            asm.lw(:t2, 4, :t0)
            asm.sw(:t2, 0, :t1)
            asm.b("rt_start_next") { asm.addiu(:t0, :t0, 8) }
            asm.label("rt_start_lists")
            asm.jal("rt_lists_start")
            asm.jal("rt_paint_upload")
            asm.jal("rt_sound_upload") if sound
            asm.jal("rt_paint_start")
            asm.jal("rt_tiles_start") if tiles
            asm.lw(:ra, 0, :sp)
            asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            routine ? asm.j(routine) : asm.jr(:ra)
          end
        end
      end
    end
  end
end
