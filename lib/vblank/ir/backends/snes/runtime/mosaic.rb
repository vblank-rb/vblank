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
          # A SCREEN SPLIT IN TWO starts its blocks again at the split (Blocks.block_top): the row a
          # status bar starts at, or the row a background is held above, where the bar's line table
          # (Picture#emit_bar_table) switches the layers. The display counts the lines of a block down
          # the screen, and sets its count back in two places only: on the first line drawn, and when
          # a write to MOSAIC switches blocks on while no background had them (bsnes, sfc/ppu/io.cpp,
          # the $2106 case: "mosaic vcounter is reloaded when mosaic becomes enabled"; and
          # sfc/ppu/mosaic.cpp, PPU::Mosaic::scanline, which counts it down at the start of each
          # line). So in such a game a channel of the copying engine (SPLIT_CHANNEL) writes MOSAIC
          # twice in the gap before the split's line, with no background switched on and then with
          # the game's: the count starts again there, and the line after the gap is a block's first.
          # Both writes are in one gap, so no line is drawn without its blocks. Its table is the bar's
          # turned to MOSAIC (SPLIT_TABLE): the game's byte twice above the split, then the pair, and
          # it is written in the blank from the bar's top and the byte noted. No processor time goes
          # on it while the screen is drawn.
          module Mosaic
            # The byte the blank writes to MOSAIC. Nought at power-on: blocks of one, which is the
            # picture as drawn.
            STATE = "rt mosaic"

            # In a game whose screen is split: the line table SPLIT_CHANNEL reads, of up to three
            # steps of a count and two bytes, and the end.
            SPLIT_TABLE = "rt mosaic split table"
            SPLIT_TABLE_BYTES = 10
            SPLIT_CHANNEL = 4
            # MOSAIC's bits for the backgrounds: the low four.
            BACKGROUND_BITS = 0x0F

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
            # blank's write and the split's table are emitted.
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

            # ...and whether it starts its blocks again at a split.
            def splits?(memory) = memory.reserved?(SPLIT_TABLE)

            # +split+ for a game whose screen a status bar or a background held above a row splits.
            def reserve(memory, split: false)
              memory.reserve(STATE, 2)
              memory.reserve(SPLIT_TABLE, SPLIT_TABLE_BYTES) if split
            end

            # SPLIT_CHANNEL's bit in HDMAEN, which the bar's table switches on and off with its own
            # (Picture#emit_bar_table).
            def split_channel_bit = 1 << SPLIT_CHANNEL

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
              emit_split_table(asm, memory) if splits?(memory)
            end

            # In the blank: MOSAIC set to the byte noted, and in a game whose screen is split, the
            # split's table made from it (rt_mosaic_split). Leaves A wide.
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
              asm.jsr(asm.abs("rt_mosaic_split")) if splits?(memory)
            end

            # rt_mosaic_split (JSR, in the blank): SPLIT_TABLE made for the bar's top as it is now, and
            # SPLIT_CHANNEL pointed at it. Above the split, in one step or two as the bar's own table
            # counts them (Picture::MOST_STEP_LINES), the byte noted twice; on the split's line the
            # byte with no background switched on and then the byte, which sets the display's count
            # of lines back; then the end, which holds the byte to the bottom of the screen. A bar at
            # the top has no step above it.
            def emit_split_table(asm, memory)
              h = Console::SNESHardware
              table = memory[SPLIT_TABLE]
              most = Picture::MOST_STEP_LINES
              channel = h::DMA_BASE + (SPLIT_CHANNEL << 4)
              asm.label("rt_mosaic_split")
              asm.ldx(0)
              asm.lda(asm.abs(memory[Picture::BAR] + Picture::BAR_TOP))
              asm.beq("rt_mosaic_split_at")
              asm.cmp(most + 1)
              asm.bcc("rt_mosaic_split_one_step")
              asm.sec
              asm.sbc(most)
              asm.sep(0x20)
              asm.sta(asm.abs(table + 3))
              asm.lda(most)
              asm.sta(asm.abs(table))
              emit_load_byte(asm, memory)
              [1, 2, 4, 5].each { |at| asm.sta(asm.abs(table + at)) }
              asm.rep(0x20)
              asm.ldx(6)
              asm.bra("rt_mosaic_split_at")
              asm.label("rt_mosaic_split_one_step")
              asm.sep(0x20)
              asm.sta(asm.abs(table))
              emit_load_byte(asm, memory)
              asm.sta(asm.abs(table + 1))
              asm.sta(asm.abs(table + 2))
              asm.rep(0x20)
              asm.ldx(3)
              asm.label("rt_mosaic_split_at")
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs_x(table))
              emit_load_byte(asm, memory)
              asm.sta(asm.abs_x(table + 2))
              asm.and_a(0xFF ^ BACKGROUND_BITS)
              asm.sta(asm.abs_x(table + 1))
              asm.stz(asm.abs_x(table + 3))
              asm.lda(h::DMA_TO_ONE_PORT_TWICE)
              asm.sta(asm.abs(channel + h::DMAP))
              asm.lda(h::MOSAIC & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.lda(table >> 16)
              asm.sta(asm.abs(channel + h::A1B))
              asm.rep(0x20)
              asm.lda(table & 0xFFFF)
              asm.sta(asm.abs(channel + h::A1TL))
              asm.rts
            end
          end
        end
      end
    end
  end
end
