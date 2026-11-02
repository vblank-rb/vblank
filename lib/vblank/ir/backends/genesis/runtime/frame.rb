# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE FRAME: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 224 of them, and then rests for 38 more
          # lines' worth of time — the VERTICAL BLANK — before it starts again. A game changes the
          # picture's memories (video RAM, colour memory, scroll memory) in that rest, or with the
          # screen switched off, so a pass of the game loop ends by waiting for it (rt_wait_vblank): the
          # processor sleeps (STOP) until the video chip's interrupt wakes it. Then what the pass
          # changed in the picture is copied to the console (Runtime::Picture), and the buttons are
          # taken for the next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits,
          # and waits for the next one: the game slows down rather than tearing.
          #
          # What the run is doing is kept where a reader of the running cartridge can find it
          # (Genesis::HeadlessRun): how many passes have ended, which pass the screen is showing,
          # whether the game is waiting at a frame boundary, and whether it has stopped or gone
          # wrong and why. The names and their meanings are the Color's and the Super Nintendo's, so a
          # reader of any of them asks the same questions.
          module Frame
            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in FAULT's first word: the number every cartridge console's runtime
            # keeps for it (Backends::CartridgeFaults).
            include CartridgeFaults

            # FAULT: what went wrong (a word), the list's place (a long), and two numbers that say
            # how (a long each).
            FAULT_LIST = 2
            FAULT_FIRST = 6
            FAULT_SECOND = 10
            FAULT_BYTES = 14

            STATE = "rt state" # RUNNING, HALTED or WENT_WRONG
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # passes of the game loop ended, 32 bits
            SHOWN = "rt shown" # the pass whose picture the console shows, 32 bits
            HELD = "rt held" # the buttons held through the pass, a bit each in IR::Buttons's order
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault"
            # Set by whoever reads the run when it has the pass it wanted last: the game shows that
            # pass and goes no further.
            HOLD = "rt hold"
            # Set by the same reader when it has taken the last pass it compares one by one: the
            # game's timers do not move on at the boundary after it, as the interpreter's do not.
            LAST_PASS_TAKEN = "rt last pass taken"
            # HOW MANY FRAMES A PASS TOOK (IR::Frames): the interrupt counts every frame (FRAMES, 32
            # bits); where a pass's wait ends, the frames since the last wait ended are what that pass
            # answers for (FRAMES_TAKEN), and held between one and IR::Frames::MOST (STEP_TAKEN).
            FRAMES = "rt frames"
            FRAMES_MARK = "rt frames mark"
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken"
            # ...and the real number for each of the last STEPS_KEPT passes, a byte each, by the
            # pass's number less its multiples of STEPS_KEPT, for a reader of the run.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # The buttons as the interrupt reads them on every frame: held at the last, and every
            # one that went down on any of them since the last wait ended.
            PAD_HELD = "rt pad held"
            PAD_PRESSED = "rt pad pressed"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the screen is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # Each button's bit in the number the runtime keeps them in, in IR::Buttons's order: the
            # pad has seven of them and the order has thirteen, so the bits between are never set.
            BUTTON_BITS = Ractor.make_shareable(Buttons::NAMES.each_with_index.to_h { |name, bit| [name, 1 << bit] })

            # The status register's value that lets every interrupt in (supervisor mode, mask 0), and
            # the mask bits that keep every one out.
            INTERRUPTS_ON = 0x2000
            INTERRUPTS_OFF_BITS = 0x0700

            module_function

            def reserve(memory)
              memory.reserve(STATE, 2)
              memory.reserve(WAITING, 2)
              memory.reserve(PASSES, 4)
              memory.reserve(SHOWN, 4)
              memory.reserve(HELD, 2)
              memory.reserve(SEEN, 2)
              memory.reserve(PRESSED, 2)
              memory.reserve(FAULT, FAULT_BYTES)
              memory.reserve(HOLD, 4)
              memory.reserve(LAST_PASS_TAKEN, 4)
              memory.reserve(FRAMES, 4)
              memory.reserve(FRAMES_MARK, 2)
              memory.reserve(STEP_TAKEN, 2)
              memory.reserve(FRAMES_TAKEN, 2)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(PAD_HELD, 2)
              memory.reserve(PAD_PRESSED, 2)
              memory.reserve(VBLANK, 2)
              memory.reserve(DISPLAY_ON, 2)
            end

            # The routines that end a pass and start the next: the interrupt, the wait, the buttons,
            # stopping and going wrong. +sound+ for a game that makes sound, whose wait ends in Sound's
            # rt_sound_frame.
            def emit(asm, memory, sound: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_interrupt(asm, at)
              emit_wait(asm, at, sound)
              emit_show_pass(asm, at)
              emit_buttons(asm, memory, at)
              emit_stopping(asm, at)
            end

            # The interrupt that says a frame has been drawn. It keeps every register it touches, counts
            # the frame and reads the buttons, so a pass that spans several frames answers for each of
            # them, as the interpreter's does. A5 is the game's own and is never changed.
            def emit_interrupt(asm, at)
              asm.label("rt_vblank_interrupt")
              asm.movem_push(:l, :d0, :d1, :d2, :d3)
              asm.jsr(asm.abs_l("rt_pad_read"))
              asm.addq(:l, 1, at.call(FRAMES))
              asm.move(:w, asm.imm(1), at.call(VBLANK))
              asm.movem_pop(:l, :d0, :d1, :d2, :d3)
              asm.rte
              asm.label("rt_unused_interrupt")
              asm.rte
            end

            # The end of a pass: count it, move on what keeps time by the frame, say the game is
            # waiting, and wait for the screen. What keeps time by the frame moves on here, before
            # the game is said to be waiting, because that is where the interpreter moves it on: at
            # the frame boundary, before anything is read of the frame (Reference#advance_frame).
            def emit_wait(asm, at, sound)
              asm.label("rt_wait_vblank")
              asm.addq(:l, 1, at.call(PASSES))
              asm.jsr(asm.abs_l("rt_frame_begins_unless_last"))
              asm.jsr(asm.abs_l("rt_tint_prepare"))
              asm.jsr(asm.abs_l("rt_picture_prepare"))
              asm.move(:w, asm.imm(1), at.call(WAITING))
              asm.jsr(asm.abs_l("rt_show_pass"))
              asm.tst(:l, at.call(HOLD))
              asm.branch(:eq, "rt_wait_vblank_buttons")
              asm.jmp(asm.abs_l("rt_stopped"))
              asm.label("rt_wait_vblank_buttons")
              asm.jsr(asm.abs_l("rt_read_buttons"))
              asm.clr(:w, at.call(WAITING))
              asm.jsr(asm.abs_l("rt_sound_frame")) if sound # the music of the frames the pass took (Sound)
              asm.rts

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.tst(:l, at.call(LAST_PASS_TAKEN))
              asm.branch(:ne, "rt_frame_begins_skipped")
              asm.jsr(asm.abs_l("rt_frame_begins"))
              asm.label("rt_frame_begins_skipped")
              asm.rts
            end

            # rt_show_pass: what the pass drew, on the screen, and SHOWN saying so. The first time, the
            # screen is still off, so everything set up so far is copied while nothing is drawn, and
            # the screen comes on in the blank after, showing it; after that, the pass's changes are
            # copied in the blank.
            #
            # THE FRAMES ARE COUNTED FROM THE SCREEN COMING ON. Setting up and the first copy take
            # several frames of the console's time with nothing to see, and the interpreter's first
            # pass takes one: the count starts again as the picture first shows, with that frame as
            # the first, so a game counting frames (a timer, an effect that runs every frame) counts
            # the same ones, and the buttons the interrupt of that frame read are the first frame's.
            def emit_show_pass(asm, at)
              asm.label("rt_show_pass")
              asm.tst(:w, at.call(DISPLAY_ON))
              asm.branch(:ne, "rt_show_pass_on")
              asm.jsr(asm.abs_l("rt_upload_whole"))
              asm.jsr(asm.abs_l("rt_sleep_until_vblank"))
              asm.jsr(asm.abs_l("rt_screen_on"))
              asm.move(:l, asm.imm(1), at.call(FRAMES))
              asm.move(:w, asm.imm(1), at.call(FRAMES_MARK))
              asm.move(:w, asm.imm(1), at.call(DISPLAY_ON))
              asm.bra("rt_show_pass_shown")
              asm.label("rt_show_pass_on")
              asm.jsr(asm.abs_l("rt_sleep_until_vblank"))
              asm.jsr(asm.abs_l("rt_upload"))
              asm.label("rt_show_pass_shown")
              asm.move(:l, at.call(PASSES), at.call(SHOWN))
              asm.rts

              # Sleep until the blank's interrupt has come since this was called. The interrupt is
              # held off while the flag is looked at, so one cannot come between the look and the sleep
              # and be waited a whole frame for; STOP lets the pending one in as it sleeps.
              asm.label("rt_sleep_until_vblank")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.clr(:w, at.call(VBLANK))
              asm.label("rt_sleep_until_vblank_wait")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.tst(:w, at.call(VBLANK))
              asm.branch(:ne, "rt_sleep_until_vblank_done")
              asm.stop(INTERRUPTS_ON)
              asm.bra("rt_sleep_until_vblank_wait")
              asm.label("rt_sleep_until_vblank_done")
              asm.move_to_sr(asm.imm(INTERRUPTS_ON))
              asm.rts
            end

            # BUTTONS. The pad is read by hand through its port: with its select line high it shows C,
            # B, right, left, down and up, and with it low start and A, a pressed button reading 0.
            # The pad needs a moment after the line changes, which is two instructions that do
            # nothing. The bits are turned into IR::Buttons's order.
            def emit_buttons(asm, memory, at)
              h = Console::GenesisHardware
              # rt_buttons_now: D0 = the buttons held now, a bit each in IR::Buttons's order.
              asm.label("rt_buttons_now")
              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(h::PAD1_DATA))
              2.times { asm.nop }
              asm.move(:b, asm.abs_l(h::PAD1_DATA), asm.d(1))
              asm.move(:b, asm.imm(0), asm.abs_l(h::PAD1_DATA))
              2.times { asm.nop }
              asm.move(:b, asm.abs_l(h::PAD1_DATA), asm.d(2))
              asm.not(:b, asm.d(1))
              asm.not(:b, asm.d(2))
              asm.moveq(0, asm.d(0))
              h::PAD_BITS.each do |name, (half, bit)|
                asm.btst(bit, asm.d(half == :high ? 1 : 2))
                asm.branch_over(:eq, 4)
                asm.or(:w, asm.imm(BUTTON_BITS.fetch(name)), asm.d(0))
              end
              asm.rts

              # In the interrupt, every frame: the buttons held now, and every one that went down
              # since the frame before added to those pressed during the pass.
              asm.label("rt_pad_read")
              asm.jsr(asm.abs_l("rt_buttons_now"))
              asm.move(:w, at.call(SEEN), asm.d(2))
              asm.not(:w, asm.d(2))
              asm.and(:w, asm.d(0), asm.d(2))
              asm.or(:w, at.call(PAD_PRESSED), asm.d(2))
              asm.move(:w, asm.d(2), at.call(PAD_PRESSED))
              asm.move(:w, asm.d(0), at.call(PAD_HELD))
              asm.move(:w, asm.d(0), at.call(SEEN))
              asm.rts

              emit_read_buttons(asm, memory, at)
            end

            # Where a pass's wait ends: the buttons for the pass about to start, from every frame the
            # last one took, and how many frames that was. The interrupt is held off while they are
            # taken, so a press it reads cannot fall between the two; one that came while it was held
            # off is taken as soon as it is allowed again.
            def emit_read_buttons(asm, memory, at)
              asm.label("rt_read_buttons")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.move(:w, at.call(PAD_PRESSED), at.call(PRESSED))
              asm.clr(:w, at.call(PAD_PRESSED))
              asm.move(:w, at.call(PAD_HELD), at.call(HELD))
              asm.move(:l, at.call(FRAMES), asm.d(0))
              asm.move_to_sr(asm.imm(INTERRUPTS_ON))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.sub(:w, at.call(FRAMES_MARK), asm.d(1))
              asm.move(:w, asm.d(0), at.call(FRAMES_MARK))
              asm.and(:l, asm.imm(0xFF), asm.d(1))
              asm.branch(:ne, "rt_read_buttons_some")
              asm.moveq(1, asm.d(1)) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.move(:w, asm.d(1), at.call(FRAMES_TAKEN))
              asm.move(:l, at.call(PASSES), asm.d(2))
              asm.and(:l, asm.imm(STEPS_KEPT - 1), asm.d(2))
              asm.lea(asm.abs_l(memory[STEPS]), asm.a(0))
              asm.move(:b, asm.d(1), asm.idx(0, 0, 2))
              asm.cmp(:w, asm.imm(IR::Frames::MOST + 1), asm.d(1))
              asm.branch(:cs, "rt_read_buttons_step")
              asm.move(:w, asm.imm(IR::Frames::MOST), asm.d(1))
              asm.label("rt_read_buttons_step")
              asm.move(:w, asm.d(1), at.call(STEP_TAKEN))
              asm.rts
            end

            # STOPPING. rt_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or with the screen switched on, for a game
            # that never got as far as a frame), SHOWN says the end is on the screen, and the
            # processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first (rt_fault, D0 = what went wrong, the list and the numbers already in FAULT).
            def emit_stopping(asm, at)
              asm.label("rt_halt")
              asm.moveq(HALTED, asm.d(0))
              asm.label("rt_stop_with_state")
              asm.move(:w, asm.d(0), at.call(STATE))
              asm.jsr(asm.abs_l("rt_tint_prepare"))
              asm.jsr(asm.abs_l("rt_picture_prepare"))
              asm.jsr(asm.abs_l("rt_show_pass"))
              asm.move(:l, asm.imm(END_SHOWN), at.call(SHOWN))
              asm.label("rt_stopped")
              asm.stop(INTERRUPTS_ON)
              asm.bra("rt_stopped")

              asm.label("rt_fault")
              asm.move(:w, asm.d(0), at.call(FAULT))
              asm.moveq(WENT_WRONG, asm.d(0))
              asm.bra("rt_stop_with_state")

              # Where the processor lands when it meets something it cannot do (an odd address, a
              # bad instruction, a division by nought): the game stops, saying so.
              asm.label("rt_exception")
              asm.moveq(CPU_EXCEPTION, asm.d(0))
              asm.bra("rt_fault")
            end
          end
        end
      end
    end
  end
end
