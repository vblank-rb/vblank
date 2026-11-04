# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SUPER FX, PUT TO WORK BY THE CONSOLE (a cartridge with that chip only).
          #
          # The Super FX is a second processor inside the cartridge (SNES::GSU says what it is). The
          # console's processor hands it a program address and lets it go; it runs from the
          # cartridge's ROM and writes into its own RAM, and stops itself with STOP. Two rules make
          # the handing over safe on a real console, both from how the board is wired (fullsnes,
          # "SNES Cart GSU-n Memory Map" and "I/O Ports"; bsnes, sfc/coprocessor/superfx/bus.cpp):
          #
          #   - WHILE IT RUNS IT OWNS THE ROM AND ITS RAM (SCMR's RON and RAN bits). The console's
          #     processor reading the ROM then gets nothing useful (bsnes hands it the same few
          #     bytes, whatever the address), so the console cannot run its own code from the
          #     cartridge while it waits: the waiting loop is copied into work RAM at power-on and
          #     runs from there (rt_chip_wait, at WAIT).
          #   - ITS INTERRUPTS GO TO WORK RAM. The console finds an interrupt's routine by reading
          #     its address (its "vector") from the end of the ROM's first bank. While the chip owns
          #     the ROM, the cartridge answers every read of the ROM with the same sixteen bytes,
          #     picked by the address's last four bits, and those bytes are laid out so that each
          #     vector reads as an address in work RAM's second page: the vertical blank's interrupt
          #     (the NMI, whose vector is at $FFEA) as $0108, and the other interrupt (the IRQ, at
          #     $FFEE) as $010C (bsnes, SuperFX::CPUROM::read in sfc/coprocessor/superfx/bus.cpp).
          #     So a long jump is written at $0108 (NMI_LANDING), to a copy of the whole vertical
          #     blank's interrupt kept in work RAM (INTERRUPT), and a return at $010C (IRQ_LANDING).
          #     That copy reads nothing from the cartridge, which would answer with the same sixteen
          #     bytes: the buttons' reading is written into it rather than called
          #     (Frame#emit_interrupt_whole). So the interrupt keeps coming while the chip runs: every
          #     frame is counted and every frame's buttons read, as the interpreter counts and reads
          #     them however long a pass is. Those bytes are in the vertical blank's own direct page,
          #     whose first bytes nothing else uses (Memory). The moment the chip stops, the vectors
          #     read from the ROM again and the cartridge's own interrupt is taken; the two keep the
          #     same counts in the same places, so it does not matter which of them a blank lands in.
          #
          #     The music is not played in the interrupt but where a pass's wait ends, once for each
          #     frame the pass took (Sound's rt_sound_frame), and it reads its notes from the ROM. So
          #     a long chip run is caught up at the end of its pass, as any long pass is, and nothing
          #     of the music needs the ROM while the chip has it. The sound unit goes on sounding the
          #     notes it was given meanwhile, as it does through any long pass.
          #
          # The chip runs at 21 MHz (CLSR), and is told not to interrupt the console when it stops
          # (CFGR): the waiting loop sees its GO bit fall instead.
          #
          # What the chip runs is a game's routines marked `on_chip: true` (ChipCode).
          module Chip
            WAIT = "rt chip wait"
            INTERRUPT = "rt chip interrupt"
            WAIT_BYTES = 32
            # Where the console goes for each interrupt while the chip owns the ROM.
            NMI_LANDING = 0x0108
            IRQ_LANDING = 0x010C

            module_function

            # +extra_buttons+ and +second_controller+ say what the interrupt reads, as Frame.emit is
            # told. Its size does not hang on which byte of the direct page it reads the controller
            # in, so it is measured with any.
            def reserve(memory, extra_buttons: false, second_controller: false)
              memory.reserve(WAIT, WAIT_BYTES)
              size = interrupt_code(memory, pad: 0, extra_buttons: extra_buttons, second_controller: second_controller).bytesize
              memory.reserve_far(INTERRUPT, size)
            end

            # rt_chip_start: the chip set up, and the waiting loop and the interrupt copied into work
            # RAM with the jumps to the interrupt written, once, at power-on. rt_chip_run: the GSU
            # program at the 24-bit address in R0's low three bytes run to its STOP, with R0's fourth
            # byte the picture's layout bits for SCMR (its colours and height; nought when it plots
            # nothing). Both are called long (JSL) with A, X and Y 16 bits wide, and give them back
            # so. The chip's other registers ($3000-$301D) are the caller's to set before
            # rt_chip_run. +pad+, +extra_buttons+ and +second_controller+ are what Frame.emit is told.
            def emit(asm, memory, pad:, extra_buttons: false, second_controller: false)
              interrupt = interrupt_code(memory, pad: pad, extra_buttons: extra_buttons, second_controller: second_controller)
              emit_start(asm, memory, interrupt)
              emit_run(asm, memory)
            end

            def emit_start(asm, memory, interrupt)
              h = Console::SNESHardware
              asm.label("rt_chip_start")
              asm.sep(0x20)
              asm.lda(h::GSU_FAST_CLOCK)
              asm.sta(asm.abs(h::GSU_CLSR))
              asm.lda(h::GSU_IRQ_OFF)
              asm.sta(asm.abs(h::GSU_CFGR))
              asm.stz(asm.abs(h::GSU_SCMR))
              emit_copy(asm, "rt_chip_wait_code", memory[WAIT], wait_code.bytesize)
              emit_copy(asm, "rt_chip_interrupt_code", memory[INTERRUPT], interrupt.bytesize)
              emit_interrupt_landings(asm, memory[INTERRUPT])
              asm.rep(0x20)
              asm.rtl
              asm.label("rt_chip_wait_code")
              asm.data_bytes(wait_code.unpack("C*"))
              asm.label("rt_chip_interrupt_code")
              asm.data_bytes(interrupt.unpack("C*"))
            end

            # +count+ bytes from the cartridge at +from+ to work RAM at +to+ (a long address), A 8 bits
            # wide.
            def emit_copy(asm, from, to, count)
              asm.ldx(0)
              asm.label("#{from}_copy")
              asm.lda(asm.long_x(from))
              asm.sta(asm.long_x(to | 0x7E0000))
              asm.inx
              asm.cpx(count)
              asm.bne("#{from}_copy")
            end

            # JML to +interrupt+ at NMI_LANDING, and RTI at IRQ_LANDING, A 8 bits wide.
            def emit_interrupt_landings(asm, interrupt)
              jml = W65816::OPERATED[:jml][:long]
              bytes = [jml, interrupt & 0xFF, (interrupt >> 8) & 0xFF, interrupt >> 16, W65816::SINGLES[:rti]]
              bytes.each_with_index do |byte, at|
                asm.lda(byte)
                asm.sta(asm.abs(NMI_LANDING + at))
              end
            end

            def emit_run(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_chip_run")
              asm.sep(0x20)
              # The chip sees the cartridge's ROM in banks $00-$3F, where the console sees it in
              # banks $80-$BF as well. Setting the bank empties the chip's quick memory, so a bank
              # that is already the one is left alone, and code run again keeps it (ChipFill).
              asm.lda(asm.direct(2))
              asm.and_a(0x3F)
              asm.cmp(asm.abs(h::GSU_PBR))
              asm.beq("rt_chip_run_same_bank")
              asm.sta(asm.abs(h::GSU_PBR))
              asm.label("rt_chip_run_same_bank")
              asm.lda(asm.direct(3))
              asm.ora(h::GSU_OWNS_ROM | h::GSU_OWNS_RAM)
              asm.rep(0x30)
              asm.and_a(0x00FF)
              asm.tax # what SCMR will say, handed to the waiting loop
              asm.lda(asm.direct(0)) # where the program starts, the same
              asm.jsl(asm.long(memory[WAIT]))
              asm.rep(0x20)
              asm.rtl
            end

            # The waiting loop, as bytes to copy into work RAM. Called long with A, X and Y 16 bits
            # wide, A the program's address and X what SCMR is to say, it hands the chip the ROM and
            # its RAM and starts it, goes round until the chip's GO bit falls, and takes the ROM and
            # RAM back. All of that is here rather than in the cartridge because from the moment the
            # chip owns the ROM until it gives it back, the console must not read an instruction from
            # there. The vertical blank's interrupt goes on meanwhile, through NMI_LANDING. Its
            # branches are relative and every address it names is fixed, so it runs wherever it is
            # copied to. It gives A back 8 bits wide.
            def wait_code
              h = Console::SNESHardware
              asm = W65816.new("rt chip wait")
              asm.tay
              asm.sep(0x20)
              asm.txa
              asm.sta(asm.abs(h::GSU_SCMR))
              asm.rep(0x20)
              asm.tya
              # Writing R15's high byte starts the chip: a 16-bit store writes $301E, then $301F.
              asm.sta(asm.abs(h::GSU_R15))
              asm.sep(0x20)
              asm.label("wait")
              asm.lda(asm.abs(h::GSU_SFR))
              asm.and_a(h::GSU_GO)
              asm.bne("wait")
              asm.stz(asm.abs(h::GSU_SCMR)) # the ROM and the RAM are the console's again
              asm.rtl
              code = Linker.new([asm.section]).link.bytes.byteslice(0, asm.here)
              raise "the chip's waiting loop is #{code.bytesize} bytes, over #{WAIT_BYTES}" if code.bytesize > WAIT_BYTES

              code
            end

            # The vertical blank's interrupt whole (Frame#emit_interrupt_whole), as bytes to copy
            # into work RAM.
            def interrupt_code(memory, pad:, extra_buttons:, second_controller:)
              asm = W65816.new("rt chip interrupt")
              Frame.emit_interrupt_whole(asm, memory, pad: pad, extra_buttons: extra_buttons, second_controller: second_controller)
              Linker.new([asm.section]).link.bytes.byteslice(0, asm.here)
            end
          end
        end
      end
    end
  end
end
