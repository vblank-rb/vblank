# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # From power-on to the game's first line.
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
          # the work RAM the game uses, the video RAM its picture reads before writing it (Cleared),
          # the colour memory and the sprite table. The screen stays off
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
            def emit(asm, main:, cleared:, fast: true, counted: false)
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
              counted ? emit_memories_cleared_counted(asm, cleared) : emit_memories_cleared(asm, cleared)
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

            # What setting up clears, and nothing else: the copying engine takes eight of the console's
            # clock cycles a byte with the processor stopped, so all 128K of work RAM and all 64K of video
            # RAM were most of the first six frames. +work_ram+ is the ranges of long addresses the build
            # placed something in (Memory#placed_ranges); +video_ram+ the ranges of word addresses the
            # picture reads before the game has written them whole, a length in words each
            # (#video_ram_read). The colour memory and the sprite table are always cleared whole.
            Cleared = Data.define(:work_ram, :video_ram)

            # A range of video RAM: its first word and how many words.
            VideoRange = Data.define(:word, :words)

            # The video RAM the picture reads and does not write whole before it is shown. On a tiled
            # screen the backgrounds' and sprites' tiles in use are copied in by the picture's start
            # (Runtime::Picture: tile 0 among them, the empty cell), and every other tile is named by no
            # cell and no sprite until something copies it in first; but a layer's map is shown whether
            # the game put a background up on it or not, and a map put up covers only its own cells, so
            # the maps are cleared, an empty cell being tile 0: the two layers' and, where it is on, the
            # third's. A painted screen's start leaves cells showing its clear tile, which is black only
            # because video RAM starts at nought, so a painted screen's is cleared whole.
            def video_ram_read(painted:, third_layer:)
              return Ractor.make_shareable([VideoRange.new(word: 0, words: 0x8000)]) if painted

              maps = Picture::LAYER_MAPS.map { |word| VideoRange.new(word: word, words: 0x1000) }
              maps.unshift(VideoRange.new(word: Picture::THIRD_LAYER_MAP, words: 0x400)) if third_layer
              Ractor.make_shareable(maps)
            end

            # Work RAM, video RAM, the colour memory and the sprite table, all noughts, by the copying
            # engine's channel 0 from a byte of nought in the cartridge (rt_zero): each a range of
            # +cleared+ (a Cleared), copies of 64K at most.
            def emit_memories_cleared(asm, cleared)
              emit_video_ram_cleared(asm, cleared.video_ram, 0x10000)
              emit_colors_and_sprites_cleared(asm)
              cleared.work_ram.each { |range| emit_work_ram_cleared(asm, range, 0x10000) }
            end

            # The same memories cleared with the screen's interrupt counting the frames it takes.
            #
            # The processor stops while the copying engine works, so the interrupt of a blank that
            # begins during a copy waits for the copy to end. It is not lost, but only one can wait:
            # a copy that outlasts a frame loses a blank. So every copy here is COUNTED_FILL_BYTES at
            # most, well under a frame. (Reading whether a blank has begun between copies would not do:
            # the mark a blank sets is cleared again as the blank ends.)
            #
            # The interrupt keeps its numbers in the first 8K of work RAM, which the first copy
            # clears: the power comes on at the top of the picture, and the first blank begins
            # most of a frame later. The interrupt is switched on then, and the rest is cleared: the
            # video RAM, the colours, the sprites and the rest of work RAM.
            def emit_memories_cleared_counted(asm, cleared)
              first, *rest = cleared.work_ram
              head = first.begin...[first.begin + COUNTED_FILL_BYTES, first.end].min
              emit_work_ram_cleared(asm, head, COUNTED_FILL_BYTES)
              Runtime.emit_interrupt_on(asm)
              emit_video_ram_cleared(asm, cleared.video_ram, COUNTED_FILL_BYTES)
              emit_colors_and_sprites_cleared(asm)
              emit_work_ram_cleared(asm, head.end...first.end, COUNTED_FILL_BYTES) if head.end < first.end
              rest.each { |range| emit_work_ram_cleared(asm, range, COUNTED_FILL_BYTES) }
            end

            # The colour memory, 512 bytes, and the sprite table, 544. A sprite at nought would show at
            # the top left, so every sprite is put below the screen afterwards by the picture's own start
            # (Runtime::Picture).
            def emit_colors_and_sprites_cleared(asm)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::CGDATA & 0xFF, 512)
              asm.stz(asm.abs(h::OAMADDL))
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::OAMDATA & 0xFF, 544)
            end

            # Each range of video RAM (VideoRange), the two ports by turns, in copies of +most+ bytes.
            def emit_video_ram_cleared(asm, ranges, most)
              h = Console::SNESHardware
              ranges.each do |range|
                asm.lda(range.word)
                asm.sta(asm.abs(h::VMADDL))
                emit_fills(asm, h::DMA_TO_TWO_PORTS | h::DMA_FIXED_SOURCE, h::VMDATAL & 0xFF, range.words * 2, most)
              end
            end

            # The long addresses of +range+, through work RAM's own port from its first, in copies of
            # +most+ bytes: the port's address is the distance from $7E:0000, seventeen bits of it.
            def emit_work_ram_cleared(asm, range, most)
              h = Console::SNESHardware
              distance = range.begin - WORK_RAM_START
              asm.lda(distance & 0xFFFF)
              asm.sta(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.lda(distance >> 16)
              asm.sta(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              emit_fills(asm, h::DMA_FIXED_SOURCE, h::WMDATA & 0xFF, range.size, most)
            end

            # Where work RAM starts as a long address.
            WORK_RAM_START = 0x7E0000

            # +bytes+ to the port $21+port, in copies of +most+ bytes at most; a copy of 64K is a count
            # of nought.
            def emit_fills(asm, mode, port, bytes, most)
              bytes.fdiv(most).ceil.times do |i|
                emit_fill(asm, mode, port, [most, bytes - (i * most)].min & 0xFFFF)
              end
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
