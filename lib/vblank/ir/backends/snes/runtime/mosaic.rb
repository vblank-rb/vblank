# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE BACKGROUNDS IN BLOCKS (`pixelate size, sprites: false`), which the console's display
          # does as it draws: one register, MOSAIC ($2106), whose top four bits are a block's size
          # less one and whose low four bits switch it on for BG1 to BG4. It has no switch for the
          # sprites, which is why a game for this console says `sprites: false`. Nothing in memory
          # moves, so a size costs a store in the blank however much is on the screen.
          #
          # THE RULE THE DISPLAY KEEPS, which the interpreter draws (Reference#paint_scenery_in_blocks):
          # a block starts at every column and every line of the screen that is a multiple of its size,
          # counted from the screen's top left, and shows the pixel its background has at the block's
          # first column on the block's first line. Across, bsnes's background renderer reloads a
          # counter to the size at the start of every line and takes a new pixel each time it runs
          # out, the first at column 0; down, its mosaic counter starts on the first line drawn and
          # every line of a block reads the background at that block's first line (bsnes,
          # sfc/ppu/mosaic.cpp and sfc/ppu/background.cpp; fullsnes, "SNES PPU Mosaic": "the mosaic
          # starts at the upper-left of the screen"). Super Bomberman's stage end is the shipped
          # example: its status bar's lines match this rule on every frame of the fade.
          #
          #   rt_mosaic(size)   the size noted: held to 1..16 as Blocks.size holds it, made into
          #                     the register's byte with the backgrounds this game puts in blocks
          #
          # The blank writes the byte noted (#emit_write), where it writes the brightness, so a
          # size set in a pass shows on that pass's picture as a fade's level does.
          #
          # A SCREEN SPLIT IN TWO keeps the one grid. The bar's line table (Picture#emit_bar_table)
          # switches layers between two lines, and MOSAIC is not written there, so the display's
          # count of a block's lines runs on through the split, as it does in Super Bomberman, whose
          # line interrupt changes the layers and the scroll at its bar's last line and never MOSAIC.
          # A line inside a block reads its background at the block's first line (the line less the
          # count), with the layers and the scroll registers as they are on that line (bsnes,
          # sfc/ppu/background.cpp, PPU::Background::fetchNameTable, and #run, which tests the
          # layer's enable as it is now). So a block that starts above a status bar shows, on its
          # lines from the bar down, the bar's layer read above the bar's first row.
          module Mosaic
            # The byte the blank writes to MOSAIC. Nought at power-on: blocks of one, which is the
            # picture as drawn.
            STATE = "rt mosaic"

            R = Ractor.make_shareable(->(n) { Memory.register(n) })

            module_function

            # In a game with a layer in blocks in one scene and not in another: that layer's bit while
            # the scene up leaves it as drawn, which the scene notes as it takes over
            # (Lowering::Picture#emit_scene_mosaic) and the blank takes out of the byte it writes.
            # Nought at power-on, before any scene, when only the scenery every scene shows is up,
            # and that is in blocks or not the same way in each.
            KEPT_LAYERS = "rt mosaic layers kept"

            # Whether the runtime keeps a mosaic: a game that pixelates.
            def kept?(memory) = memory.reserved?(STATE)

            # ...and whether its scenes differ in which layers are in blocks.
            def by_scene?(memory) = memory.reserved?(KEPT_LAYERS)

            # KEPT_LAYERS, reserved by the lowering the first time a scene notes it.
            # Must run while the game is lowered, before Runtime.sections: #by_scene? decides how the
            # blank's write is emitted.
            def reserve_kept_layers(memory)
              memory.reserve(KEPT_LAYERS, 2) unless by_scene?(memory)
            end

            # The byte to write to MOSAIC, into A, which is narrow: the byte noted, less the layers the
            # scene up leaves as drawn.
            def emit_load_byte(asm, memory)
              if by_scene?(memory)
                asm.lda(asm.abs(memory[KEPT_LAYERS]))
                asm.eor(0xFF)
                asm.and_a(asm.abs(memory[STATE]))
              else
                asm.lda(asm.abs(memory[STATE]))
              end
            end

            def reserve(memory)
              memory.reserve(STATE, 2)
            end

            # rt_mosaic, for a game whose blocks reach the backgrounds +backgrounds+ (a bit each,
            # BG1's the lowest, as MOSAIC takes them).
            def emit(asm, memory, backgrounds:)
              asm.label("rt_mosaic")
              asm.lda(asm.direct(R.call(0) + 2))
              asm.bmi("rt_mosaic_least")
              asm.bne("rt_mosaic_most")
              asm.lda(asm.direct(R.call(0)))
              asm.beq("rt_mosaic_least")
              asm.cmp(Blocks::LARGEST + 1)
              asm.bcc("rt_mosaic_held")
              asm.label("rt_mosaic_most")
              asm.lda(Blocks::LARGEST)
              asm.bra("rt_mosaic_held")
              asm.label("rt_mosaic_least")
              asm.lda(1)
              asm.label("rt_mosaic_held")
              asm.dec
              4.times { asm.asl }
              asm.ora(backgrounds)
              asm.sta(asm.abs(memory[STATE]))
              asm.rtl
            end

            # In the blank: MOSAIC set to the byte noted. Leaves A wide.
            def emit_write(asm, memory)
              if by_scene?(memory)
                asm.sep(0x20)
                emit_load_byte(asm, memory)
              else
                asm.lda(asm.abs(memory[STATE]))
                asm.sep(0x20)
              end
              asm.sta(asm.abs(Console::SNESHardware::MOSAIC))
              asm.rep(0x20)
            end
          end
        end
      end
    end
  end
end
