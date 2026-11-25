# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # From power-on to the game's first line.
          #
          # The 68000 wakes up with every interrupt held off, reads the stack's first place and the
          # place to start from the first two long words of the cartridge, and starts there
          # (Cartridge::GenesisROM's vectors). Nothing the console keeps is cleared at power-on, so the
          # first thing done is to put it all in a known state.
          #
          # The security check. A console of the later kind refuses to show anything until the cartridge
          # has written the letters SEGA to a port, and only that kind has the port: the version
          # register shows which (Console::GenesisHardware's TMSS_PORT). The write is made only when the
          # version asks for it.
          #
          # The sound processor starts running memory nobody filled and can write noise into the sound
          # chip, so its bus is asked for and kept, which stops it; and the sound chip's four square
          # voices are turned off, since they power on at a volume of their own choosing.
          #
          # The video chip is told its settings (a table of its registers the lowering writes, since the
          # size of a picture's planes is the game's), and its three memories — video RAM, colour
          # memory and scroll memory — are cleared, video RAM by the chip's own fill while the processor
          # clears work RAM (#emit_memories_cleared), the screen off all the while: it stays off until
          # the end of the first pass of the game, when what the game set up is on it (Runtime::Frame).
          # Work RAM is cleared by code that makes no calls, since the stack lives in it.
          module Boot
            module_function

            # The entry points the vectors name: reset, the interrupt of the vertical blank, and the
            # interrupts and faults a game has no use for.
            def emit_vectors(asm)
              asm.label("rt_reset")
              asm.jmp(asm.abs_l("rt_boot"))
            end

            # rt_boot: the console made ready, then the game's main routine, +main+, for good.
            #
            # +counting+ (a Frame::CountingBlock) for a game that reads how many frames it has shown since
            # power-on. Clearing the memories takes several frames, setting up after it may take more, and
            # those are shown frames like any other. So for such a game the screen's interrupt is switched on
            # as soon as the video chip is set up, counting only (Frame::COUNTING), with the part of work RAM
            # it counts in cleared first and left alone by the clearing after (#emit_counting_on).
            #
            # +second+ (a SecondPad) for a game that reads the second pad (Frame#reads_second_pad?), and
            # +team_player+ for one that reads a Team Player there, whose buttons from power-on are read
            # once work RAM is cleared (Frame#emit_tap_held_from_power_on) in place of the pad's.
            def emit(asm, main:, registers:, held_at:, counting: nil, second: nil, team_player: false)
              h = Console::GenesisHardware
              asm.label("rt_boot")
              asm.move_to_sr(asm.imm(0x2700)) # every interrupt held off
              emit_buttons_from_power_on(asm, h, second: !second.nil?)
              emit_security_check(asm, h)
              emit_sound_quiet(asm, h)
              emit_video_chip(asm, h, registers)
              emit_counting_on(asm, counting) if counting
              emit_memories_cleared(asm, h, kept_bytes: counting ? counting.bytes : 0, counting: !counting.nil?)
              asm.movea(:l, asm.imm(Memory::BASE), asm.a(5))
              asm.move(:w, asm.d(7), asm.disp(5, held_at))
              if team_player
                asm.jsr(asm.abs_l("rt_tap_held_from_power_on"))
              elsif second
                emit_second_held_from_power_on(asm, second)
              end
              asm.jsr(asm.abs_l("rt_start"))
              asm.jsr(asm.abs_l(main))
              asm.label("rt_main_returned")
              asm.jmp(asm.abs_l("rt_halt"))
            end

            # The buttons held from power-on are read first of all, before anything that takes a frame:
            # a player's hand is on the pad before the console is on. They are kept in D7 until work RAM
            # is cleared, and are the first pass's (Frame::HELD), down before the first frame boundary and
            # not yet seen there, so the first boundary still finds them going down.
            #
            # In a game that reads the second pad (+second+), its port is set the same way and its
            # buttons kept in D7's high half.
            def emit_buttons_from_power_on(asm, h, second: false)
              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(h::PAD1_CONTROL))
              asm.jsr(asm.abs_l("rt_buttons_now"))
              asm.move(:l, asm.d(0), asm.d(7))
              return unless second

              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(h::PAD2_CONTROL))
              asm.jsr(asm.abs_l("rt_second_buttons_now"))
              asm.swap(asm.d(0))
              asm.or(:l, asm.d(0), asm.d(7))
            end

            # Where the second pad's buttons held from power-on go (Frame::SECOND_HELD), and whether a
            # button on it makes the second player connected (Frame::PLAYERS_PAST_FIRST): each a distance
            # from A5.
            SecondPad = Data.define(:held_at, :connected_at)

            # The second pad's buttons from power-on, in D7's high half, made the first pass's; a
            # button down there connects the second player from the first pass, as the interpreter's
            # `hold` does (Reference#count_connected_players).
            def emit_second_held_from_power_on(asm, second)
              asm.swap(asm.d(7))
              asm.move(:w, asm.d(7), asm.disp(5, second.held_at))
              asm.branch(:eq, "rt_boot_second_quiet")
              asm.move(:w, asm.imm(1), asm.disp(5, second.connected_at))
              asm.label("rt_boot_second_quiet")
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

            # The interrupt on, counting only: A5 set, the CountingBlock +counting+ at the start of work RAM
            # cleared, COUNTING set in it, and the screen's interrupt switched on (Runtime#emit_interrupt_on).
            # The interrupt then counts frames and nothing else until setting up ends (Runtime#emit_start).
            def emit_counting_on(asm, counting)
              asm.movea(:l, asm.imm(Memory::BASE), asm.a(5))
              asm.lea(asm.abs_l(Memory::FIRST), asm.a(0))
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.imm((counting.bytes / 4) - 1), asm.d(1))
              asm.label("rt_boot_clear_counting")
              asm.move(:l, asm.d(0), asm.post(0))
              asm.dbra(asm.d(1), "rt_boot_clear_counting")
              asm.move(:w, asm.imm(1), asm.disp(5, counting.flag_at))
              Runtime.emit_interrupt_on(asm)
            end

            # VIDEO RAM, 64K, is filled by the video chip itself while the processor clears work RAM. Written
            # through the data port it was the processor's work, a long word an instruction, the chip taking
            # each at its own pace. A DMA fill instead takes one word through the data port and writes its
            # byte into as many places as the DMA length registers name (nought is 64K), the address moving on
            # by the increment register each time, all on the chip's own access slots: the processor is not
            # stopped, unlike a copy from work RAM, and goes on to clear work RAM while it runs. Asked for by
            # a write command with the DMA bit (COMMAND_DMA) when the mode register lets the chip do DMA and
            # the top two bits of register 23 are 2. Nothing may write the chip's registers until the fill
            # is done, since that ends it early, so the processor waits on the status's DMA-busy bit (bit 1)
            # after work RAM before it clears the colours and the scroll memory a word at a time as before.
            # (Genesis Plus GX, core/vdp_ctrl.c: vdp_68k_ctrl_w's DMA Fill case, vdp_68k_data_w,
            # vdp_dma_fill, and the transfer counts atop vdp_dma_update.)
            #
            # Work RAM, all of it but its first +kept_bytes+, which the interrupt counts in
            # (#emit_counting_on), is cleared by code that makes no call, from the top down: MOVEM writes
            # eight registers of noughts below A0 in one instruction, eight of those a turn, so the loop's
            # own instructions are paid once every 256 bytes; the bytes left below the last whole turn are
            # cleared a long word at a time. D7 holds the buttons from power-on and is not one of them.
            def emit_memories_cleared(asm, h, kept_bytes: 0, counting: false)
              asm.moveq(0, asm.d(0))
              emit_video_ram_fill_started(asm, h, counting: counting)
              emit_work_ram_cleared(asm, h, kept_bytes)
              asm.label("rt_boot_video_ram_filling")
              asm.move(:w, asm.abs_l(h::VDP_CONTROL), asm.d(1))
              asm.btst(VDP_STATUS_DMA_BUSY, asm.d(1))
              asm.branch_near(:ne, "rt_boot_video_ram_filling")
              asm.move(:w, asm.imm(register_word(h, h::REG_INCREMENT, h::INCREMENT_WORD)), asm.abs_l(h::VDP_CONTROL))
              emit_clear_words(asm, h, h::WRITE_CRAM, h::CRAM_COLORS, "rt_boot_clear_colors")
              emit_clear_words(asm, h, h::WRITE_VSRAM, h::VSRAM_WORDS, "rt_boot_clear_scroll")
            end

            # The status's bit that is set while the chip is doing a DMA.
            VDP_STATUS_DMA_BUSY = 1

            # Register 23's top two bits for a fill.
            DMA_FILL = 0x80

            # The registers a MOVEM writes noughts from, a long word each, and how many it writes a turn.
            ZERO_REGISTERS = %i[d0 d1 d2 d3 d4 d5 a1 a2].freeze
            MOVEMS_A_TURN = 8

            def register_word(h, register, value) = h::VDP_REGISTER | (register << 8) | value

            # The fill of all 64K of video RAM with nought, started: the address moving on a byte at a time,
            # the length nought (64K), register 23 set for a fill, DMA let on in the mode register (with the
            # interrupt where it is on, #emit_counting_on), and the command with the DMA bit, then the word
            # whose byte fills it.
            def emit_video_ram_fill_started(asm, h, counting:)
              mode2 = h::MODE2_SCREEN_OFF | h::MODE2_DMA | (counting ? h::MODE2_VBLANK_INTERRUPT : 0)
              length = h::VRAM_SIZE & 0xFFFF # 64K is nought in the length registers
              [[h::REG_MODE2, mode2], [h::REG_INCREMENT, 1],
               [h::REG_DMA_LENGTH_LOW, length & 0xFF], [h::REG_DMA_LENGTH_HIGH, length >> 8],
               [h::REG_DMA_SOURCE_HIGH, DMA_FILL]].each do |register, value|
                asm.move(:w, asm.imm(register_word(h, register, value)), asm.abs_l(h::VDP_CONTROL))
              end
              asm.move(:l, asm.imm(Console::GenesisHardware.command(h::WRITE_VRAM, 0) | h::COMMAND_DMA), asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
            end

            def emit_work_ram_cleared(asm, h, kept_bytes)
              turn_bytes = ZERO_REGISTERS.length * 4 * MOVEMS_A_TURN
              turns, left = (h::WRAM_SIZE - kept_bytes).divmod(turn_bytes)
              ZERO_REGISTERS.each do |register|
                register.start_with?("a") ? asm.movea(:l, asm.d(0), asm.a(register[1].to_i)) : asm.moveq(0, asm.d(register[1].to_i))
              end
              asm.lea(asm.abs_l(h::WRAM + h::WRAM_SIZE), asm.a(0))
              asm.move(:w, asm.imm(turns - 1), asm.d(6))
              asm.label("rt_boot_clear_work_ram")
              MOVEMS_A_TURN.times { asm.movem_push(:l, *ZERO_REGISTERS, via: 0) }
              asm.dbra(asm.d(6), "rt_boot_clear_work_ram")
              return if left.zero?

              asm.move(:w, asm.imm((left / 4) - 1), asm.d(6))
              asm.label("rt_boot_clear_work_ram_left")
              asm.move(:l, asm.d(0), asm.pre(0))
              asm.dbra(asm.d(6), "rt_boot_clear_work_ram_left")
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
