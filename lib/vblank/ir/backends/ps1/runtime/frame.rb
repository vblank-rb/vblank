# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE FRAME: waiting for the screen, the interrupt, stopping, and going wrong.
          #
          # The television draws the picture a line at a time, 240 of them, and then rests for the
          # remaining lines of the 263 a frame has — the VERTICAL BLANK — before it starts again. The
          # graphics chip raises an interrupt as the rest begins, and the runtime's handler (rt_interrupt)
          # counts the frame and reads the pad, every frame, whatever the game is doing. A pass of the
          # game loop ends by waiting for that interrupt (rt_wait_vblank), then takes the buttons for the
          # next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits, and
          # waits for the next one: the game slows down rather than tearing. The interrupt counts every
          # frame, so the pass answers for all of them, as the interpreter's does.
          #
          # What the run is doing is kept where a reader of the running program can find it
          # (PS1::HeadlessRun): how many passes have ended, which pass the screen is showing, whether the
          # game is waiting at a frame boundary, and whether it has stopped or gone wrong and why. The
          # names and their meanings are every cartridge console's, so a reader of any of them asks the
          # same questions. Each is a word.
          module Frame
            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in FAULT's first word: the number every cartridge console's runtime keeps
            # for it (Backends::CartridgeFaults).
            include CartridgeFaults

            # FAULT: what went wrong, the list's place, and two numbers that say how, a word each.
            FAULT_LIST = 4
            FAULT_FIRST = 8
            FAULT_SECOND = 12
            FAULT_BYTES = 16

            STATE = "rt state"
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # Passes of the game loop ended
            SHOWN = "rt shown" # The pass whose picture the console shows
            HELD = "rt held" # The buttons held through the pass, a bit each in IR::Buttons's order
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault"
            # Set by whoever reads the run when it has the pass it wanted last: the game shows that pass
            # and goes no further.
            HOLD = "rt hold"
            # Set by the same reader when it has taken the last pass it compares one by one: the game's
            # timers do not move on at the boundary after it, as the interpreter's do not.
            LAST_PASS_TAKEN = "rt last pass taken"
            # HOW MANY FRAMES A PASS TOOK (IR::Frames): the interrupt counts every frame (FRAMES); where a
            # pass's wait ends, the frames since the last wait ended are what that pass answers for
            # (FRAMES_TAKEN), and held between one and IR::Frames::MOST (STEP_TAKEN).
            FRAMES = "rt frames"
            FRAMES_MARK = "rt frames mark"
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken"
            # ...and the real number for each of the last STEPS_KEPT passes, a byte each, by the pass's
            # number less its multiples of STEPS_KEPT, for a reader of the run.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # HOW LATE A PASS WAS. The console's line timer (PS1Hardware::TIMER1_COUNT) as the last blank
            # began, kept by the interrupt (BLANK_LINE); and for each of the last STEPS_KEPT passes, a half
            # each, how many lines the screen had drawn since then as the pass went to sleep (END_LINES),
            # by the same number as STEPS. A pass that took several frames went to sleep after a blank began
            # while it ran, and those lines are how much sooner it had to end to take a frame fewer. Only a
            # reader of the run asks (Diagnostics::PS1Profiler); the game never does.
            BLANK_LINE = "rt blank line"
            END_LINES = "rt end lines"
            # The buttons as the interrupt reads them on every frame: held at the last, and every one that
            # went down on any of them since the last wait ended.
            PAD_HELD = "rt pad held"
            PAD_PRESSED = "rt pad pressed"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the picture is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"
            # Where the interrupt keeps the registers of the code it stopped.
            SAVED = "rt saved registers"

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # The registers the interrupt's handler keeps, since the code it stops may be using any of
            # them (and the handler calls routines that may change them), and HI and LO after them.
            KEPT_REGISTERS = %i[at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 ra].freeze

            WORDS = [STATE, WAITING, PASSES, SHOWN, HELD, SEEN, PRESSED, HOLD, LAST_PASS_TAKEN, FRAMES,
                     FRAMES_MARK, STEP_TAKEN, FRAMES_TAKEN, PAD_HELD, PAD_PRESSED, VBLANK, DISPLAY_ON,
                     BLANK_LINE].freeze

            module_function

            def reserve(memory)
              WORDS.each { |name| memory.reserve(name, 4) }
              memory.reserve(FAULT, FAULT_BYTES)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(END_LINES, STEPS_KEPT * 2)
              memory.reserve(SAVED, (KEPT_REGISTERS.size + 2) * 4)
            end

            # The routines that end a pass and start the next: the interrupt, the wait, the buttons,
            # stopping and going wrong.
            def emit(asm, memory)
              at = ->(name) { Runtime.at(memory, name) }
              emit_interrupt(asm, at)
              emit_wait(asm, at)
              emit_show_pass(asm, at)
              emit_read_buttons(asm, at)
              emit_stopping(asm, at)
            end

            # THE INTERRUPT. Every register the handler or the routines it calls may change is kept first,
            # and HI and LO with them, since the code it stopped may be between a multiply and the read of
            # its answer. Only a vertical blank is let through (I_MASK), and it is acknowledged by writing
            # a nought to its bit of I_STAT. Then back where the processor was stopped (EPC), with RFE in
            # the jump's delay slot, which puts back the interrupts-on state the exception saved.
            def emit_interrupt(asm, at)
              h = Console::PS1Hardware
              saved = at.call(SAVED)
              asm.label("rt_interrupt")
              KEPT_REGISTERS.each_with_index { |name, i| asm.sw(name, saved + (i * 4), :gp) }
              asm.mfhi(:t0)
              asm.mflo(:t1)
              asm.sw(:t0, saved + (KEPT_REGISTERS.size * 4), :gp)
              asm.sw(:t1, saved + ((KEPT_REGISTERS.size + 1) * 4), :gp)
              asm.lui(:t2, h::IO >> 16)
              asm.lw(:t0, h::I_STAT & 0xFFFF, :t2)
              asm.andi(:t0, :t0, h::IRQ_VBLANK)
              asm.beq(:t0, :zero, "rt_interrupt_done")
              asm.li(:t0, ~h::IRQ_VBLANK & 0xFFFF_FFFF)
              asm.sw(:t0, h::I_STAT & 0xFFFF, :t2)
              asm.lw(:t0, at.call(FRAMES), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(FRAMES), :gp)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(VBLANK), :gp)
              asm.lhu(:t0, h::TIMER1_COUNT & 0xFFFF, :t2)
              asm.sw(:t0, at.call(BLANK_LINE), :gp)
              asm.jal("rt_pad_read")
              asm.label("rt_interrupt_done")
              asm.lw(:t0, saved + (KEPT_REGISTERS.size * 4), :gp)
              asm.lw(:t1, saved + ((KEPT_REGISTERS.size + 1) * 4), :gp)
              asm.mthi(:t0)
              asm.mtlo(:t1)
              KEPT_REGISTERS.each_with_index { |name, i| asm.lw(name, saved + (i * 4), :gp) }
              asm.mfc0(:k0, R3000::COP0_EPC)
              asm.jr(:k0) { asm.rfe }
            end

            # The end of a pass: count it, move on what keeps time by the frame, say the game is waiting,
            # and wait for the screen. What keeps time by the frame moves on here, before the game is said
            # to be waiting, because that is where the interpreter moves it on: at the frame boundary,
            # before anything is read of the frame (Reference#advance_frame).
            def emit_wait(asm, at)
              asm.label("rt_wait_vblank")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lw(:t0, at.call(PASSES), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(PASSES), :gp)
              asm.jal("rt_frame_begins_unless_last")
              # The page this pass drew, kept where a reader finds it while the game waits: the pages
              # may trade places before the game stops waiting.
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.sw(:t0, at.call(Paint::PASS_PAGE_Y), :gp)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(Paint::FLIP_OWED), :gp) # the page this pass drew is shown
              asm.sw(:t0, at.call(WAITING), :gp)
              emit_end_lines_store(asm, at)
              asm.jal("rt_show_pass")
              asm.lw(:t0, at.call(HOLD), :gp)
              asm.bne(:t0, :zero, "rt_stopped")
              asm.jal("rt_read_buttons")
              asm.sw(:zero, at.call(WAITING), :gp)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN). A jump, not a
              # call: rt_frame_begins returns straight to the caller.
              asm.label("rt_frame_begins_unless_last")
              asm.lw(:t0, at.call(LAST_PASS_TAKEN), :gp)
              asm.beq(:t0, :zero, "rt_frame_begins")
              asm.jr(:ra)
            end

            # THE MOMENT THE PASS ENDS: END_LINES for it, the lines since the last blank began, and VBLANK
            # cleared, so the wait (rt_show_pass) catches the first blank that begins from here on. Both
            # with the interrupt held off, so no blank can come between reading the timer and clearing
            # VBLANK: one that did would be missed by the wait and counted from the blank before. The
            # timer's count turns round at 16 bits, and so does the difference.
            def emit_end_lines_store(asm, at)
              asm.mtc0(:zero, R3000::COP0_STATUS)
              asm.lui(:t1, Console::PS1Hardware::IO >> 16)
              asm.lw(:t2, at.call(BLANK_LINE), :gp)
              asm.lhu(:t0, Console::PS1Hardware::TIMER1_COUNT & 0xFFFF, :t1)
              asm.lw(:t1, at.call(PASSES), :gp)
              asm.subu(:t0, :t0, :t2)
              asm.andi(:t0, :t0, 0xFFFF)
              asm.andi(:t1, :t1, STEPS_KEPT - 1)
              asm.sll(:t1, :t1, 1)
              asm.addu(:t1, :t1, :gp)
              asm.sh(:t0, at.call(END_LINES), :t1)
              asm.sw(:zero, at.call(VBLANK), :gp)
              asm.li(:t0, Console::PS1Hardware::SR_INTERRUPTS_ON)
              asm.mtc0(:t0, R3000::COP0_STATUS)
            end

            # rt_show_pass: the pass on the screen, and SHOWN saying so. The first time, the picture is
            # still off, and it comes on in the blank after.
            #
            # THE FRAMES ARE COUNTED FROM THE PICTURE COMING ON. Setting up takes frames of the console's
            # time with nothing to see, and the interpreter's first pass takes one: the count starts again
            # as the picture first shows, with that frame as the first, so a game counting frames counts
            # the same ones.
            def emit_show_pass(asm, at)
              h = Console::PS1Hardware
              asm.label("rt_show_pass")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lw(:t0, at.call(DISPLAY_ON), :gp)
              asm.bne(:t0, :zero, "rt_show_pass_on")
              asm.jal("rt_sleep_until_vblank")
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, h::GP1_DISPLAY_ON)
              asm.sw(:t0, h::GP1 & 0xFFFF, :t1)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(FRAMES), :gp)
              asm.sw(:t0, at.call(FRAMES_MARK), :gp)
              asm.b("rt_show_pass_shown") { asm.sw(:t0, at.call(DISPLAY_ON), :gp) }
              # VBLANK was cleared where the pass ended (#emit_end_lines_store), or where the game stopped.
              asm.label("rt_show_pass_on")
              asm.jal("rt_sleep_until_vblank_wait")
              asm.label("rt_show_pass_shown")
              # A tear-free screen's pages trade places in the blank, before SHOWN says the pass is up.
              asm.jal("rt_paint_flip")
              asm.lw(:t0, at.call(Paint::SHOWN_PAGE_Y), :gp)
              asm.sw(:t0, at.call(Paint::PASS_SHOWN_PAGE_Y), :gp)
              asm.lw(:t0, at.call(PASSES), :gp)
              asm.sw(:t0, at.call(SHOWN), :gp)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }

              # Wait until the blank's interrupt has come since this was called.
              asm.label("rt_sleep_until_vblank")
              asm.sw(:zero, at.call(VBLANK), :gp)
              asm.label("rt_sleep_until_vblank_wait")
              asm.lw(:t0, at.call(VBLANK), :gp)
              asm.beq(:t0, :zero, "rt_sleep_until_vblank_wait")
              asm.jr(:ra)
            end

            # Where a pass's wait ends: the buttons for the pass about to start, from every frame the last
            # one took, and how many frames that was. The interrupt is held off while they are taken, so a
            # press it reads cannot fall between the two.
            def emit_read_buttons(asm, at)
              asm.label("rt_read_buttons")
              asm.mtc0(:zero, R3000::COP0_STATUS)
              asm.lw(:t0, at.call(PAD_PRESSED), :gp)
              asm.sw(:zero, at.call(PAD_PRESSED), :gp)
              asm.sw(:t0, at.call(PRESSED), :gp)
              asm.lw(:t0, at.call(PAD_HELD), :gp)
              asm.lw(:t2, at.call(FRAMES), :gp)
              asm.sw(:t0, at.call(HELD), :gp)
              asm.li(:t0, Console::PS1Hardware::SR_INTERRUPTS_ON)
              asm.mtc0(:t0, R3000::COP0_STATUS)
              asm.lw(:t1, at.call(FRAMES_MARK), :gp)
              asm.sw(:t2, at.call(FRAMES_MARK), :gp)
              asm.subu(:t1, :t2, :t1)
              asm.andi(:t1, :t1, 0xFF)
              asm.bne(:t1, :zero, "rt_read_buttons_some")
              asm.li(:t1, 1) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.sw(:t1, at.call(FRAMES_TAKEN), :gp)
              asm.lw(:t2, at.call(PASSES), :gp)
              asm.andi(:t2, :t2, STEPS_KEPT - 1)
              asm.addu(:t2, :t2, :gp)
              asm.sb(:t1, at.call(STEPS), :t2)
              asm.sltiu(:t0, :t1, IR::Frames::MOST + 1)
              asm.bne(:t0, :zero, "rt_read_buttons_step")
              asm.li(:t1, IR::Frames::MOST)
              asm.label("rt_read_buttons_step")
              asm.jr(:ra) { asm.sw(:t1, at.call(STEP_TAKEN), :gp) }
            end

            # STOPPING. rt_halt stops the game where it is: SHOWN says the end is on the screen once the
            # blank after it has come, and the processor goes round a loop from then on, the interrupt still
            # counting frames. Going wrong is the same, with what went wrong written down first (rt_fault,
            # a0 = what went wrong, the list and the numbers already in FAULT).
            def emit_stopping(asm, at)
              asm.label("rt_halt")
              asm.li(:t0, HALTED)
              asm.label("rt_stop_with_state")
              asm.sw(:t0, at.call(STATE), :gp)
              asm.sw(:zero, at.call(VBLANK), :gp)
              asm.jal("rt_show_pass")
              asm.li(:t0, END_SHOWN)
              asm.sw(:t0, at.call(SHOWN), :gp)
              asm.label("rt_stopped")
              asm.b("rt_stopped")

              asm.label("rt_fault")
              asm.sw(:a0, at.call(FAULT), :gp)
              asm.b("rt_stop_with_state") { asm.li(:t0, WENT_WRONG) }
            end
          end
        end
      end
    end
  end
end
