# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # FROM POWER-ON TO THE GAME'S FIRST LINE.
          #
          # The processor wakes up pretending to be a 6502: 8-bit registers, 64K of addresses, and
          # the reset vector read from the end of the cartridge's first bank. The first thing done
          # is to leave that ("native mode": clear the carry, swap it into the emulation flag with
          # XCE), and the next is to jump to the same code in the fast copy of the cartridge (bank
          # $80) and tell the console it can read that copy quickly (MEMSEL).
          #
          # Then everything the console keeps is put in a known state, since nothing of it is
          # cleared at power-on: the stack at the top of the first 8K of work RAM, the direct page
          # at its bottom, the data bank at $80 (so a 16-bit address reaches that 8K, the hardware's
          # registers and the cartridge's first bank alike), every register of the picture chip,
          # all of work RAM, video RAM, the colour memory and the sprite table. The screen stays off
          # ("forced blank") until the end of the first pass of the game, when what the game set up
          # is on it (Runtime::Frame).
          #
          # The copying engine (DMA) does the clearing: told to copy one byte, from a place that
          # does not move, to a port, 64K times, it fills video RAM in a few lines of the screen's
          # time where the processor would take most of a frame.
          module Boot
            module_function

            # The section in the cartridge's first bank: the reset and the interrupts' entry points,
            # each of which jumps on to the fast copy at once.
            def emit_vectors(asm)
              asm.label("rt_reset")
              asm.sei
              asm.clc
              asm.xce # native mode
              asm.jml(asm.long("rt_boot"))
              asm.label("rt_nmi")
              asm.jml(asm.long("rt_vblank_interrupt"))
              asm.label("rt_irq")
              asm.rti
            end

            # How much one copy of a counted clearing fills (#emit_memories_cleared_counted): a quarter
            # of video RAM or an eighth of work RAM, which the copying engine fills in well under a
            # frame, at eight of the console's clock cycles a byte.
            COUNTED_FILL_BYTES = 0x4000

            # rt_boot: the console made ready, then the game's main routine, +main+, for good.
            # +fast+ is false on a board whose ROM is only read at the slow speed (a Super FX's):
            # MEMSEL is then left at its power-on nought, and banks $80 and up are read as slowly
            # as banks $00 and up, which that ROM can keep up with.
            #
            # +counted+ for a game that reads how many frames it has shown since power-on. Clearing
            # the memories takes several frames, and setting up after it more, and the screen's
            # interrupt, which counts them (Frame::FRAMES), must be on through all of it. So its
            # memories are cleared in the order #emit_memories_cleared gives, with the interrupt
            # switched on as soon as the part of work RAM the interrupt keeps its numbers in is
            # cleared.
            def emit(asm, main:, fast: true, counted: false)
              h = Console::SNESHardware
              asm.label("rt_boot")
              asm.rep(0x30)
              asm.lda(Memory::STACK_TOP)
              asm.tcs
              asm.lda(0)
              asm.tcd
              asm.sep(0x20)
              asm.lda(0x80)
              asm.pha
              asm.plb # the data bank: $80
              if fast
                asm.lda(1)
                asm.sta(asm.abs(h::MEMSEL)) # the fast copy, read fast
              end
              asm.lda(h::FORCED_BLANK)
              asm.sta(asm.abs(h::INIDISP))
              asm.stz(asm.abs(h::NMITIMEN))
              asm.rep(0x20)
              emit_registers_cleared(asm)
              counted ? emit_memories_cleared_counted(asm) : emit_memories_cleared(asm)
              asm.jsl(asm.long("rt_start"))
              asm.jsl(asm.long(main))
              asm.label("rt_main_returned")
              asm.jml(asm.long("rt_halt"))
            end

            # Every register of the picture chip at nought but the ones that want something else:
            # the screen off, sprites of 8 and 16 pixels, and the video RAM address moving on a word
            # after each write of its high byte.
            def emit_registers_cleared(asm)
              h = Console::SNESHardware
              asm.sep(0x20)
              (h::OBSEL..h::COLDATA).each do |register|
                next if register == h::VMDATAL || register == h::VMDATAH || register == h::CGDATA || register == h::OAMDATA

                asm.stz(asm.abs(register))
                # The scroll and mode 7 registers are written twice, low byte then high.
                asm.stz(asm.abs(register)) if (h::BG1HOFS..h::BG4VOFS).cover?(register) || (h::M7A..h::M7Y).cover?(register)
              end
              asm.lda(h::VMAIN_WORD)
              asm.sta(asm.abs(h::VMAIN))
              asm.lda(0xE0) # colour maths' fixed colour: black, all three
              asm.sta(asm.abs(h::COLDATA))
              asm.stz(asm.abs(h::SETINI))
              asm.stz(asm.abs(h::WRIO))
              asm.stz(asm.abs(h::HDMAEN))
              asm.rep(0x20)
            end

            # Work RAM, video RAM, the colour memory and the sprite table, all noughts, by the copying
            # engine's channel 0 from a byte of nought in the cartridge (rt_zero).
            def emit_memories_cleared(asm)
              h = Console::SNESHardware
              # Video RAM: 64K, the two ports by turns.
              asm.stz(asm.abs(h::VMADDL))
              emit_fill(asm, h::DMA_TO_TWO_PORTS | h::DMA_FIXED_SOURCE, h::VMDATAL & 0xFF, 0)
              # The colour memory: 512 bytes.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::CGDATA & 0xFF, 512)
              # The sprite table: 544 bytes. A sprite at nought would show at the top left, so every
              # sprite is put below the screen afterwards by the picture's own start (Runtime::Picture).
              asm.stz(asm.abs(h::OAMADDL))
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::OAMDATA & 0xFF, 544)
              # Work RAM, all 128K but the stack in use: through its own port, from $7E:0000, two
              # copies of 64K.
              asm.stz(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.stz(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              2.times { emit_fill(asm, h::DMA_FIXED_SOURCE, h::WMDATA & 0xFF, 0) }
            end

            # The same memories cleared with the screen's interrupt counting the frames it takes.
            #
            # The processor stops while the copying engine works, so the interrupt of a blank that
            # begins during a copy waits for the copy to end. It is not lost, but only one can wait:
            # a copy that outlasts a frame loses a blank. So every copy here is COUNTED_FILL_BYTES,
            # well under a frame. (Reading whether a blank has begun between copies would not do:
            # the mark a blank sets is cleared again as the blank ends.)
            #
            # The interrupt keeps its numbers in the first 8K of work RAM, which the first copy
            # clears: the power comes on at the top of the picture, and the first blank begins
            # most of a frame later. The interrupt is switched on then, and the rest is cleared: the
            # video RAM, the colours, the sprites and the rest of work RAM, whose port goes on from
            # where the first copy ended.
            def emit_memories_cleared_counted(asm)
              h = Console::SNESHardware
              asm.stz(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.stz(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::WMDATA & 0xFF, COUNTED_FILL_BYTES)
              Runtime.emit_interrupt_on(asm)
              asm.stz(asm.abs(h::VMADDL))
              emit_fill(asm, h::DMA_TO_TWO_PORTS | h::DMA_FIXED_SOURCE, h::VMDATAL & 0xFF, COUNTED_FILL_BYTES)
              emit_fill_repeated(asm, "rt_boot_video_ram_cleared", (0x10000 / COUNTED_FILL_BYTES) - 1)
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::CGDATA & 0xFF, 512)
              asm.stz(asm.abs(h::OAMADDL))
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::OAMDATA & 0xFF, 544)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::WMDATA & 0xFF, COUNTED_FILL_BYTES)
              emit_fill_repeated(asm, "rt_boot_work_ram_cleared", (0x20000 / COUNTED_FILL_BYTES) - 2)
            end

            # The last fill made again +times+ times more, COUNTED_FILL_BYTES each, counted in Y: a fill
            # from a byte that does not move leaves every setting of the channel but its count as it was.
            # +label+ names the loop.
            def emit_fill_repeated(asm, label, times)
              h = Console::SNESHardware
              asm.ldy(times)
              asm.label(label)
              asm.lda(COUNTED_FILL_BYTES)
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.dey
              asm.bne(label)
            end

            # Channel 0 copying the byte at rt_zero to the port $21+port, +count+ times (0 is 65536).
            def emit_fill(asm, mode, port, count)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(mode)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(port)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(asm.bank_of("rt_zero"))
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.rep(0x20)
              asm.lda(asm.imm("rt_zero"))
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.lda(count)
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # The byte of nought the fills copy from, and the word of nought beside it.
            def emit_zero(asm)
              asm.label("rt_zero")
              asm.data_words(0)
            end
          end
        end
      end
    end
  end
end
