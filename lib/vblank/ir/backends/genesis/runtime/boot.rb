# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # FROM POWER-ON TO THE GAME'S FIRST LINE.
          #
          # The 68000 wakes up with every interrupt held off, reads the stack's first place and the
          # place to start from the first two long words of the cartridge, and starts there
          # (Cartridge::GenesisROM's vectors). Nothing the console keeps is cleared at power-on, so the
          # first thing done is to put it all in a known state.
          #
          # THE SECURITY CHECK. A console of the later kind refuses to show anything until the cartridge
          # has written the letters SEGA to a port, and only that kind has the port: the version
          # register shows which (Console::GenesisHardware's TMSS_PORT). The write is made only when the
          # version asks for it.
          #
          # THE SOUND PROCESSOR starts running memory nobody filled and can write noise into the sound
          # chip, so its bus is asked for and kept, which stops it; and the sound chip's four square
          # voices are turned off, since they power on at a volume of their own choosing.
          #
          # THE VIDEO CHIP is told its settings (a table of its registers the lowering writes, since the
          # size of a picture's planes is the game's), and its three memories — video RAM, colour
          # memory and scroll memory — are cleared by writing noughts through its data port, the
          # screen off all the while: it stays off until the end of the first pass of the game, when
          # what the game set up is on it (Runtime::Frame). Work RAM is cleared last, and by code that
          # makes no calls, since the stack lives in it.
          module Boot
            module_function

            # The entry points the vectors name: reset, the interrupt of the vertical blank, and the
            # interrupts and faults a game has no use for.
            def emit_vectors(asm)
              asm.label("rt_reset")
              asm.jmp(asm.abs_l("rt_boot"))
            end

            # rt_boot: the console made ready, then the game's main routine, +main+, for good.
            def emit(asm, main:, registers:, held_at:)
              h = Console::GenesisHardware
              asm.label("rt_boot")
              asm.move_to_sr(asm.imm(0x2700)) # every interrupt held off
              emit_buttons_from_power_on(asm, h)
              emit_security_check(asm, h)
              emit_sound_quiet(asm, h)
              emit_video_chip(asm, h, registers)
              emit_memories_cleared(asm, h)
              asm.movea(:l, asm.imm(Memory::BASE), asm.a(5))
              asm.move(:w, asm.d(7), asm.disp(5, held_at))
              asm.jsr(asm.abs_l("rt_start"))
              asm.jsr(asm.abs_l(main))
              asm.label("rt_main_returned")
              asm.jmp(asm.abs_l("rt_halt"))
            end

            # THE BUTTONS HELD FROM POWER-ON are read first of all, before anything that takes a frame:
            # a player's hand is on the pad before the console is on. They are kept in D7 until work RAM
            # is cleared, and are the first pass's (Frame::HELD), down before the first frame boundary and
            # not yet seen there, so the first boundary still finds them going down.
            def emit_buttons_from_power_on(asm, h)
              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(h::PAD1_CONTROL))
              asm.jsr(asm.abs_l("rt_buttons_now"))
              asm.move(:l, asm.d(0), asm.d(7))
            end

            def emit_security_check(asm, h)
              asm.move(:b, asm.abs_l(h::VERSION_REGISTER), asm.d(0))
              asm.and(:b, asm.imm(h::TMSS_VERSION_MASK), asm.d(0))
              asm.branch_over(:eq, 10) # the long write below: a word, a long address and a long number
              asm.move(:l, asm.imm(h::TMSS_LICENSE), asm.abs_l(h::TMSS_PORT))
            end

            def emit_sound_quiet(asm, h)
              asm.move(:w, asm.imm(h::Z80_REQUEST), asm.abs_l(h::Z80_BUS_REQUEST))
              asm.move(:w, asm.imm(h::Z80_REQUEST), asm.abs_l(h::Z80_RESET))
              h::PSG_SILENCE.each { |command| asm.move(:b, asm.imm(command), asm.abs_l(h::PSG)) }
            end

            # A read of the control port first, which makes the chip forget half a command if it was
            # given one; then each register of the table, a word each.
            def emit_video_chip(asm, h, registers)
              asm.move(:w, asm.abs_l(h::VDP_CONTROL), asm.d(0))
              asm.lea(asm.abs_l("rt_vdp_registers"), asm.a(0))
              asm.move(:w, asm.imm(registers - 1), asm.d(1))
              asm.label("rt_boot_register")
              asm.move(:w, asm.post(0), asm.abs_l(h::VDP_CONTROL))
              asm.dbra(asm.d(1), "rt_boot_register")
            end

            # Video RAM, 64K; colour memory, 64 words; vertical scroll memory, 40 words; each with the
            # chip pointed at its start and the address moving on by a word, and then work RAM, 64K,
            # which the code clears through A0 with no call.
            def emit_memories_cleared(asm, h)
              asm.moveq(0, asm.d(0))
              asm.move(:l, asm.imm(Console::GenesisHardware.command(h::WRITE_VRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, asm.imm(h::VRAM_SIZE / 4 - 1), asm.d(1))
              asm.label("rt_boot_clear_video_ram")
              asm.move(:l, asm.d(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), "rt_boot_clear_video_ram")
              emit_clear_words(asm, h, h::WRITE_CRAM, h::CRAM_COLORS, "rt_boot_clear_colors")
              emit_clear_words(asm, h, h::WRITE_VSRAM, h::VSRAM_WORDS, "rt_boot_clear_scroll")
              asm.lea(asm.abs_l(h::WRAM), asm.a(0))
              asm.move(:w, asm.imm(h::WRAM_SIZE / 4 - 1), asm.d(1))
              asm.label("rt_boot_clear_work_ram")
              asm.move(:l, asm.d(0), asm.post(0))
              asm.dbra(asm.d(1), "rt_boot_clear_work_ram")
            end

            def emit_clear_words(asm, h, kind, count, label)
              asm.move(:l, asm.imm(Console::GenesisHardware.command(kind, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, asm.imm(count - 1), asm.d(1))
              asm.label(label)
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), label)
            end
          end
        end
      end
    end
  end
end
