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

            # +picture+ is how the game draws: :painted (Paint), :tiled (Tiles), or :none.
            def reserve(memory, picture: :none, colors: false)
              Paint.reserve(memory) if picture == :painted
              Tiles.reserve(memory) if picture == :tiled
              Tint.reserve(memory) if colors && %i[painted tiled].include?(picture)
            end

            # The routines every cartridge carries, whatever the game draws: what the wait calls
            # before it shows a pass, which for a game that draws nothing is nothing, the copy of a
            # pass's changes, the whole copy and the screen switched on.
            def emit(asm, memory, picture: :none, columns: 32, camera: false, colors: false)
              case picture
              when :painted then Paint.emit(asm, memory, camera: camera, colors: colors)
              when :tiled then Tiles.emit(asm, memory, columns: columns, colors: colors)
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
              Tint.emit(asm, memory) if colors && %i[painted tiled].include?(picture)
              emit_screen_on(asm, memory)
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
