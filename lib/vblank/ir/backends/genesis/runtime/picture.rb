# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE PICTURE: what a pass changed on the screen, copied to the console in the blank
          # (rt_upload), everything at once while the screen is still off (rt_upload_whole), and the
          # part the game's own picture asks for.
          module Picture
            module_function

            # +picture+ is how the game draws: :painted (Paint), :tiled (Tiles), or :none. +sprites+ means a
            # painted screen shows sprites over its picture (`sprite ..., over_picture: true`). +scene_tiles+
            # for a tiled game whose scenes each bring their own tiles in (Tiles#emit_scene_tiles).
            def reserve(memory, picture: :none, colors: false, sprites: false, scene_tiles: false)
              Paint.reserve(memory) if picture == :painted
              Paint.reserve_sprites(memory) if picture == :painted && sprites
              Tiles.reserve(memory, scene_tiles: scene_tiles) if picture == :tiled
              Tint.reserve(memory) if colors && %i[painted tiled].include?(picture)
            end

            # The routines every cartridge carries, whatever the game draws: what the wait calls
            # before it shows a pass, which for a game that draws nothing is nothing, the copy of a
            # pass's changes, the whole copy and the screen switched on.
            # +backdrop+ for a game whose backdrop is copied from a list it recolours (Tint#emit).
            # +samples+ for a game that plays recordings, whose sound processor reads the cartridge while
            # the picture is copied (#emit_dma_started).
            def emit(asm, memory, picture: :none, columns: 32, camera: false, colors: false, backdrop: false, sprites: false,
                     scene_tiles: false, samples: false)
              case picture
              when :painted then Paint.emit(asm, memory, camera: camera, colors: colors, sprites: sprites, samples: samples)
              when :tiled then Tiles.emit(asm, memory, columns: columns, colors: colors, scene_tiles: scene_tiles, samples: samples)
              else
                asm.label("rt_picture_start")
                asm.rts
                asm.label("rt_picture_prepare")
                asm.rts
                asm.label("rt_tint_prepare")
                asm.rts
                asm.label("rt_upload")
                asm.label("rt_upload_whole")
                asm.rts
              end
              Tint.emit(asm, memory, backdrop: backdrop) if colors && %i[painted tiled].include?(picture)
              emit_screen_on(asm, memory)
            end

            # A COPY BY THE VIDEO CHIP (DMA) STARTED: the command in +command+, a data register, written to
            # the chip's control port, which +port+ points at. The chip takes the 68000's bus for itself
            # with that write and gives it back when the last word is in video memory.
            #
            # THE SOUND PROCESSOR IS STOPPED FOR IT, in a game that plays recordings (+samples+). The Z80
            # reads a recording out of the cartridge through the 68000's bus, a byte every sample, and
            # the console's maker tells its games to send the Z80 a bus request before every copy of
            # this kind, from the cartridge or from work RAM alike: on some consoles a Z80 that reaches
            # for the bus as the copy starts can spoil the copy, work RAM, or the byte the Z80 reads.
            # So the Z80 is asked for its bus and waited for, the copy runs, and the Z80 is let go, as
            # the console's own games do round theirs. The recording stands still for the length of the
            # stop, with or without the request: a Z80 that wants the cartridge while the chip holds
            # the bus waits for the copy to end anyway. Its program times its samples by the FM
            # chip's timers, which count on through a stop, and passes over the samples the stop
            # covered, so the recording keeps its pitch (Recordings#driver).
            # docs/genesis/dma-and-the-sound-processor.md has the sources.
            #
            # A game with no recordings pays nothing for that: its Z80 has been held stopped since
            # power-on (Boot#emit_sound_quiet) and never reaches for the bus.
            #
            # THE COMMAND GOES AS TWO WORDS READ FROM WORK RAM, for every game. The console's maker
            # says a copy now and then fails unless the write that starts it is a word, not a long
            # word, and is read from work RAM, and its own games keep a word of RAM for it. Here the
            # command is put on the stack, which is in work RAM, and its two halves are written from
            # there: two instructions more than one long write from the register.
            def emit_dma_started(asm, command, port, samples:)
              asm.move(:l, command, asm.pre(M68000::SP))
              asm.move(:w, asm.post(M68000::SP), port)
              Recordings.emit_bus_taken(asm) if samples
              asm.move(:w, asm.post(M68000::SP), port)
              asm.clr(:w, asm.abs_l(Console::GenesisHardware::Z80_BUS_REQUEST)) if samples
            end

            # rt_screen_on: the video chip told to show the picture and to interrupt in the blank.
            def emit_screen_on(asm, _memory)
              h = Console::GenesisHardware
              asm.label("rt_screen_on")
              asm.move(:w, asm.imm(h::VDP_REGISTER | (h::REG_MODE2 << 8) | h::MODE2_SCREEN_ON | h::MODE2_VBLANK_INTERRUPT | h::MODE2_DMA),
                       asm.abs_l(h::VDP_CONTROL))
              asm.rts
            end
          end
        end
      end
    end
  end
end
