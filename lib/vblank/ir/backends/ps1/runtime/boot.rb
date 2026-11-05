# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # FROM THE PROGRAM'S FIRST INSTRUCTION TO THE GAME'S FIRST LINE.
          #
          # Whatever loaded the program (the BIOS from a disc, an emulator, a loader over a serial cable)
          # jumps to its entry point with the stack pointer set and nothing else promised. So the
          # runtime takes the console over: interrupts off, its own stack, gp at the game's numbers, its
          # own interrupt handler, the graphics chip set up and its memory cleared, the sound chip quiet.
          # It makes no call into the BIOS, then or later, so the program behaves the same whichever BIOS
          # is in the console, or none.
          #
          # THE INTERRUPT HANDLER. On an interrupt the R3000 jumps to 80000080h, in the part of RAM the
          # BIOS's kernel keeps for itself. The runtime writes four instructions there that jump to its own
          # handler (Frame#emit_interrupt): a LUI and an ORI to put the handler's address in k0, a JR k0,
          # and a NOP for its delay slot. k0 is the one register the handler may change before it has
          # saved the others.
          #
          # THE BUTTONS HELD FROM POWER-ON are read before anything that takes a frame: a player's hand is
          # on the pad before the console is on. They are the first pass's (Frame::HELD), kept in s0 until
          # the game's region of RAM is cleared.
          module Boot
            module_function

            # rt_boot: the console made ready, then the game's main routine, +main+, for good.
            def emit(asm, memory, main:)
              h = Console::PS1Hardware
              asm.label("rt_boot")
              asm.mtc0(:zero, R3000::COP0_STATUS) # every interrupt off
              asm.li(:sp, Memory::STACK_TOP)
              asm.li(:gp, Memory::BASE)
              emit_instruction_cache_on(asm, h)
              asm.lui(:s1, h::IO >> 16) # s1: the ports, for the rest of the boot
              emit_interrupts_quiet(asm, h)
              emit_handler_installed(asm, h)
              asm.jal("rt_pads_start")
              asm.jal("rt_buttons_now")
              asm.move(:s0, :v0)
              emit_sound_quiet(asm, h)
              emit_graphics_chip(asm, h)
              emit_region_cleared(asm, memory)
              asm.sw(:s0, Runtime.at(memory, Frame::HELD), :gp)
              asm.jal("rt_start")
              emit_interrupts_on(asm, h)
              # The game starts as a frame starts, so its first pass ends in a frame after the one the
              # program was loaded in, where a reader of the run finds it waiting.
              asm.jal("rt_sleep_until_vblank")
              asm.jal(main)
              asm.label("rt_main_returned")
              asm.j("rt_halt")
              emit_gp0_word(asm, h)
            end

            # rt_gp0_word: the word in a0 sent to the graphics chip's drawing port, once the chip says it
            # can take a command word (GPUSTAT bit 26). A fill keeps the chip busy for a while, and a word
            # sent while it is busy would be lost.
            #
            # A COMMAND OF SEVERAL WORDS is sent whole: its first word through rt_gp0_word, and the rest
            # stored to GP0 straight after, through t1, which rt_gp0_word leaves holding the ports' base.
            # The chip says it has no room for a command's last word until it holds the whole command
            # (Beetle PSX measured: a textured rectangle, and a copy into video RAM, asked for between
            # their words, waited for ever). Its queue holds sixteen words, and it says it has room only
            # once it has taken every whole command it was sent, so any command fits.
            def emit_gp0_word(asm, h)
              asm.label("rt_gp0_word")
              asm.lui(:t1, h::IO >> 16)
              asm.lui(:t3, h::GPUSTAT_READY_FOR_COMMAND >> 16)
              asm.label("rt_gp0_word_wait")
              asm.lw(:t2, h::GP1 & 0xFFFF, :t1)
              asm.and(:t2, :t2, :t3)
              asm.beq(:t2, :zero, "rt_gp0_word_wait")
              asm.sw(:a0, h::GP0 & 0xFFFF, :t1)
              asm.jr(:ra)
            end

            # THE INSTRUCTION CACHE ON. The processor keeps the last 4K of code it ran in a cache inside
            # itself, and runs code from there without going out to RAM for each instruction, but only
            # once the cache control register (FFFE0130h) says so. Sony's BIOS sets it to 0001E988h
            # before it starts a program (psx-spx, "Cache Control"), so a program loaded from a disc or by
            # a loader finds it on; a program started at power-on, as ruby-ps1-emulator starts one,
            # finds it off, and runs its loops several times slower. So the runtime sets the BIOS's value
            # itself, which changes nothing on a console the BIOS has already set it on.
            def emit_instruction_cache_on(asm, h)
              asm.li(:t0, h::CACHE_CONTROL_USUAL)
              asm.li(:t1, h::CACHE_CONTROL)
              asm.sw(:t0, 0, :t1)
            end

            # Nothing the BIOS left pending reaches the processor: every interrupt masked off, and every one
            # that has happened cleared.
            def emit_interrupts_quiet(asm, h)
              asm.sw(:zero, h::I_MASK & 0xFFFF, :s1)
              asm.sw(:zero, h::I_STAT & 0xFFFF, :s1)
            end

            # The four words at the exception vector: LUI k0, hi; ORI k0, k0, lo; JR k0; NOP. Each made from
            # the handler's address at run time, from the instructions' own encodings with the halves of
            # the address filled in.
            def emit_handler_installed(asm, h)
              asm.la(:t0, "rt_interrupt")
              asm.li(:t3, h::EXCEPTION_VECTOR)
              asm.srl(:t1, :t0, 16)
              asm.lui(:t2, 0x3C1A) # LUI k0, 0
              asm.or(:t1, :t1, :t2)
              asm.sw(:t1, 0, :t3)
              asm.andi(:t1, :t0, 0xFFFF)
              asm.lui(:t2, 0x375A) # ORI k0, k0, 0
              asm.or(:t1, :t1, :t2)
              asm.sw(:t1, 4, :t3)
              asm.li(:t1, 0x0340_0008) # JR k0
              asm.sw(:t1, 8, :t3)
              asm.sw(:zero, 12, :t3)
            end

            # The sound chip's main volume at nought, and the chip off, until a game's sound is made.
            def emit_sound_quiet(asm, h)
              asm.sh(:zero, h::SPU_MAIN_VOLUME & 0xFFFF, :s1)
              asm.sh(:zero, (h::SPU_MAIN_VOLUME + 2) & 0xFFFF, :s1)
              asm.sh(:zero, h::SPU_CONTROL & 0xFFFF, :s1)
            end

            # The graphics chip reset, told to show 320 × 240 from the top left of video RAM, with the
            # picture off, drawing allowed anywhere, and every pixel of video RAM black: four fills of 512 × 256 (a fill is at most
            # 1023 across and 511 down). The picture comes on at the end of the first pass (Frame).
            def emit_graphics_chip(asm, h)
              gp1 = ->(value) { emit_port_word(asm, h::GP1, value) }
              gp0 = lambda do |value|
                asm.li(:a0, value)
                asm.jal("rt_gp0_word")
              end
              gp1.call(h::GP1_RESET)
              gp1.call(h::GP1_DISPLAY_ON | 1) # off
              gp1.call(h::GP1_DISPLAY_MODE | h::DISPLAY_MODE_320_BY_240)
              gp1.call(h::GP1_HORIZONTAL_RANGE | h::HORIZONTAL_FIRST | (h::HORIZONTAL_LAST << 12))
              gp1.call(h::GP1_VERTICAL_RANGE | h::VERTICAL_FIRST | (h::VERTICAL_LAST << 10))
              gp1.call(h::GP1_DISPLAY_START)
              gp0.call(h::GP0_DRAWING_AREA_TOP_LEFT)
              # The chip may draw anywhere in video RAM: the processor keeps every drawing inside the screen,
              # and a tear-free screen's second page is below the first (Runtime::Paint).
              gp0.call(h::GP0_DRAWING_AREA_BOTTOM_RIGHT | (h::VRAM_WIDTH - 1) | ((h::VRAM_HEIGHT - 1) << 10))
              gp0.call(h::GP0_DRAWING_OFFSET)
              # The draw mode, once, before anything is drawn: drawing where the picture shown is allowed.
              # A screen of one page always draws where it is shown, and the chip's reset leaves that bit
              # clear; Beetle PSX draws there either way, and a console's chip may not. A picture's own
              # draw mode (Runtime::Paint#emit_blit) sets the bit again with its texture page.
              gp0.call(h::GP0_DRAW_MODE | h::DRAW_ON_SHOWN_PICTURE)
              [[0, 0], [512, 0], [0, 256], [512, 256]].each do |x, y|
                gp0.call(h::GP0_FILL)
                gp0.call((y << 16) | x)
                gp0.call((256 << 16) | 512)
              end
            end

            def emit_port_word(asm, port, value)
              asm.li(:t0, value)
              asm.sw(:t0, port & 0xFFFF, :s1)
            end

            # The game's region of RAM, as far as the build used it, set to nought a word at a time.
            def emit_region_cleared(asm, memory)
              asm.li(:t0, Memory::FIRST)
              asm.li(:t1, Memory::FIRST + memory.used)
              asm.label("rt_boot_clear")
              asm.beq(:t0, :t1, "rt_boot_cleared")
              asm.sw(:zero, 0, :t0)
              asm.b("rt_boot_clear") { asm.addiu(:t0, :t0, 4) }
              asm.label("rt_boot_cleared")
            end

            # The vertical blank's interrupt let through to the processor, and the processor told to take it.
            def emit_interrupts_on(asm, h)
              asm.lui(:t1, h::IO >> 16)
              asm.sw(:zero, h::I_STAT & 0xFFFF, :t1)
              asm.li(:t0, h::IRQ_VBLANK)
              asm.sw(:t0, h::I_MASK & 0xFFFF, :t1)
              asm.li(:t0, h::SR_INTERRUPTS_ON)
              asm.mtc0(:t0, R3000::COP0_STATUS)
            end
          end
        end
      end
    end
  end
end
