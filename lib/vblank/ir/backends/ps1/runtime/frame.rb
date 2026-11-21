# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # The frame: waiting for the screen, the interrupt, stopping, and going wrong.
          #
          # The television draws the picture a line at a time, 240 of them, and then rests for the
          # remaining lines of the 263 a frame has — the vertical blank — before it starts again. The
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

            # FAULT: what went wrong, the list's place, and two numbers that give how, a word each.
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
            # The number of the last pass that reader compares, in a game whose tick handler waits
            # (LoweringPlan#keeps_last_pass_number?), nought until it is written: a boundary ending a later pass
            # moves nothing on. Such a game can end two passes in one frame, the reader seeing neither.
            LAST_PASS = "rt last pass"
            # How many frames a pass took (IR::Frames): the interrupt counts every frame (FRAMES); where a
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
            # How late a pass was. The console's line timer (PS1Hardware::TIMER1_COUNT) as the last blank
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
            # The conversation with the pad (Pads): how many of its bytes have been sent, nought for none
            # under way, and the first of the two button bytes once it has come.
            PAD_STEP = "rt pad step"
            PAD_BYTE = "rt pad byte"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the picture is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"
            # Where the interrupt keeps the registers of the code it stopped.
            SAVED = "rt saved registers"
            # 1 while a tear-free screen's timers run before the blank that shows the pass's page, for a game whose
            # handlers paint ahead (#emit_show_owed). Asked for late, beside the draw list's state.
            SHOW_OWED = "rt show owed"

            # The frames spent setting up, in a game that reads how many frames it has shown since power-on:
            # from the interrupt being switched on (Boot#emit) to the frame the first pass is shown in, kept
            # one more, for a reader of the run, so nought means not counted yet. They move nothing on but
            # that count, as the interpreter is told (Reference#frames_setting_up).
            SETTING_UP = "rt frames setting up"

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # The registers the interrupt's handler keeps, since the code it stops may be using any of
            # them (and the handler calls routines that may change them), and HI and LO after them.
            KEPT_REGISTERS = %i[at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 ra].freeze

            WORDS = [STATE, WAITING, PASSES, SHOWN, HELD, SEEN, PRESSED, HOLD, LAST_PASS_TAKEN, FRAMES,
                     FRAMES_MARK, STEP_TAKEN, FRAMES_TAKEN, PAD_HELD, PAD_PRESSED, PAD_STEP, PAD_BYTE, VBLANK,
                     DISPLAY_ON, BLANK_LINE].freeze

            module_function

            # +counted+ for a game that reads how many frames it has shown since power-on (SETTING_UP).
            def reserve(memory, counted: false)
              WORDS.each { |name| memory.reserve(name, 4) }
              memory.reserve(SETTING_UP, 4) if counted
              memory.reserve(FAULT, FAULT_BYTES)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(END_LINES, STEPS_KEPT * 2)
              memory.reserve(SAVED, (KEPT_REGISTERS.size + 2) * 4)
            end

            # LAST_PASS, in a game whose tick handler waits (LoweringPlan#keeps_last_pass_number?).
            def reserve_last_pass(memory) = memory.reserve(LAST_PASS, 4)

            # The routines that end a pass and start the next: the interrupt, the wait, the buttons,
            # stopping and going wrong. +sound+ for a game that makes sound, whose wait ends in Sound's
            # rt_sound_frame; +tiles+ for one whose screen is drawn from tiles, whose every pass ends with
            # the whole picture drawn (Tiles' rt_tiles_draw), a pass that halts too; +shown_by+ for one whose
            # painted screen is shown from pages of its own (Paint.shown_by), whose every pass ends with its page
            # copied onto the page shown by that routine of Paint's, a pass that stops too.
            #
            # +ticks_paint_ahead+ for a game with timers whose screen can be a tear-free painted one, whose
            # handlers then paint on the page after the pass's (#emit_ticks_on_next_page), its lists held back
            # meanwhile (DrawList::HELD_BACK); +crosses+ for one that hands over between painted screens and
            # screens drawn from tiles (Tiles::TILES_UP). +count_at+ is where a game that reads how many frames
            # it has shown since power-on keeps that count (#emit_setting_up_counted), nil for any other.
            def emit(asm, memory, sound: false, tiles: false, shown_by: nil, ticks_paint_ahead: false, crosses: false, count_at: nil)
              at = ->(name) { Runtime.at(memory, name) }
              emit_interrupt(asm, at, counting: !count_at.nil?)
              memory.reserve(SHOW_OWED, 4) if ticks_paint_ahead
              emit_wait(asm, memory, sound, tiles, shown_by, ticks_paint_ahead)
              if ticks_paint_ahead
                emit_ticks_on_next_page(asm, memory, crosses, shown_by)
                emit_show_owed(asm, memory, sound, shown_by)
              end
              emit_show_pass(asm, at, count_at && count_place(count_at))
              emit_read_buttons(asm, at)
              emit_stopping(asm, at, tiles, shown_by)
            end

            # The interrupt. Every register the handler or the routines it calls may change is kept first,
            # and HI and LO with them, since the code it stopped may be between a multiply and the read of
            # its answer. Only a vertical blank is let through (I_MASK), and it is acknowledged by writing
            # a nought to its bit of I_STAT. Then back where the processor was stopped (EPC), with RFE in
            # the jump's delay slot, which puts back the interrupts-on state the exception saved.
            #
            # +counting+ for a game that counts the frames setting up takes, in k1 while it does
            # (Boot#emit_counting_on): the handler only counts until k1 is nought.
            def emit_interrupt(asm, at, counting: false)
              h = Console::PS1Hardware
              saved = at.call(SAVED)
              asm.label("rt_interrupt")
              asm.bne(:k1, :zero, "rt_interrupt_counting") if counting
              KEPT_REGISTERS.each_with_index { |name, i| asm.sw(name, saved + (i * 4), :gp) }
              asm.mfhi(:t0)
              asm.mflo(:t1)
              asm.sw(:t0, saved + (KEPT_REGISTERS.size * 4), :gp)
              asm.sw(:t1, saved + ((KEPT_REGISTERS.size + 1) * 4), :gp)
              # The pad's first: a byte it has acknowledged is answered before a new conversation starts.
              asm.lui(:t2, h::IO >> 16)
              asm.lw(:t0, h::I_STAT & 0xFFFF, :t2)
              asm.andi(:t0, :t0, h::IRQ_PAD)
              asm.beq(:t0, :zero, "rt_interrupt_not_pad")
              asm.jal("rt_pad_acknowledged")
              asm.label("rt_interrupt_not_pad")
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
              emit_interrupt_counting(asm, h) if counting
            end

            # rt_interrupt_counting: the blank acknowledged and counted in k1, and nothing else, while setting up
            # runs (Boot#emit_counting_on). The only interrupt let through then is the blank's. t0 is kept just
            # below the stack, where nothing is kept, since k0 and k1 are the only registers the handler has.
            # The full handler does not look at what caused the exception either: the runtime makes none
            # but the interrupt, so this takes every one for the blank, as it does.
            def emit_interrupt_counting(asm, h)
              asm.label("rt_interrupt_counting")
              asm.sw(:t0, -4, :sp)
              asm.lui(:k0, h::IO >> 16)
              asm.li(:t0, ~h::IRQ_VBLANK & 0xFFFF_FFFF)
              asm.sw(:t0, h::I_STAT & 0xFFFF, :k0)
              asm.lw(:t0, -4, :sp)
              asm.addiu(:k1, :k1, 1)
              asm.mfc0(:k0, R3000::COP0_EPC)
              asm.jr(:k0) { asm.rfe }
            end

            # The end of a pass: count it, move on what keeps time by the frame, mark the game as waiting,
            # and wait for the screen. What keeps time by the frame moves on here, before the game is marked
            # as waiting, because that is where the interpreter moves it on: at the frame boundary,
            # before anything is read of the frame (Reference#advance_frame).
            def emit_wait(asm, memory, sound, tiles, shown_by, paint_ahead)
              at = ->(name) { Runtime.at(memory, name) }
              asm.label("rt_wait_vblank")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              if paint_ahead
                # A wait inside the timers of a pass whose page is not shown yet shows it first (#emit_show_owed).
                show_owed = show_owed_place(memory)
                asm.lui(:t1, show_owed.high)
                asm.lw(:t0, show_owed.low, :t1)
                asm.bne(:t0, :zero, "rt_wait_show_owed")
                asm.label("rt_wait_owed_shown")
              end
              asm.lw(:t0, at.call(PASSES), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(PASSES), :gp)
              if paint_ahead
                asm.jal("rt_painted_pages_up")
                asm.bne(:v0, :zero, "rt_wait_ticks_on_next_page")
              end
              asm.jal("rt_frame_begins_unless_last")
              # A screen drawn from tiles is drawn whole once the pass, its timers' routines too, has placed
              # everything, as the interpreter's picture of the pass has it.
              asm.jal("rt_tiles_draw") if tiles
              # The pass's drawing commands sent and drawn (Runtime::DrawList), before it counts as ended:
              # its picture is whole by the time it is shown or read back. A screen drawn by number is shown
              # from a copy the chip makes after them, which is whole before it is shown (Paint's rt_paint_flip).
              asm.jal("rt_draw_list_finish") unless shown_by == "rt_paint_numbers_shown"
              asm.label("rt_wait_published")
              # The page this pass drew, kept where a reader finds it while the game waits: the pages
              # may trade places before the game stops waiting.
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.sw(:t0, at.call(Paint::PASS_PAGE_Y), :gp)
              # ...and on a screen shown from pages of its own, the page shown it was copied onto.
              if shown_by
                asm.li(:a1, 1) # a pass's page published
                asm.jal(shown_by) { asm.move(:a0, :t0) }
              end
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(Paint::FLIP_OWED), :gp) # the page this pass drew is shown
              asm.sw(:t0, at.call(WAITING), :gp)
              emit_end_lines_store(asm, at)
              asm.jal("rt_show_pass")
              asm.lw(:t0, at.call(HOLD), :gp)
              asm.bne(:t0, :zero, "rt_stopped")
              # The blank that ended the wait asked the pad for its buttons; they are the next pass's.
              asm.jal("rt_pad_await")
              asm.jal("rt_read_buttons")
              asm.sw(:zero, at.call(WAITING), :gp)
              asm.jal("rt_sound_frame") if sound # the fades of the frames the pass took, and its voices started (Sound)
              asm.label("rt_wait_return")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN). A jump, not a
              # call: rt_frame_begins returns straight to the caller.
              asm.label("rt_frame_begins_unless_last")
              asm.lw(:t0, at.call(LAST_PASS_TAKEN), :gp)
              unless memory.reserved?(LAST_PASS)
                asm.beq(:t0, :zero, "rt_frame_begins")
                return asm.jr(:ra)
              end

              # ...or the pass that just ended comes after the last one it compares (LAST_PASS).
              asm.bne(:t0, :zero, "rt_frame_begins_skipped")
              asm.lw(:t0, at.call(LAST_PASS), :gp)
              asm.beq(:t0, :zero, "rt_frame_begins")
              asm.lw(:t1, at.call(PASSES), :gp)
              asm.sltu(:t0, :t0, :t1)
              asm.beq(:t0, :zero, "rt_frame_begins")
              asm.label("rt_frame_begins_skipped")
              asm.jr(:ra)
            end

            # A handler paints on the page after the pass's, on a tear-free painted screen. The interpreter trades
            # the pages at the frame boundary before the timers move on (Reference#advance_frame), so what a
            # handler paints goes on the page the next pass draws, and that pass's clear can cover it before
            # it is ever shown. So here the pass's own commands are sent and drawn first, its page is done, and
            # the timers run with PAGE_Y naming the other page; then PAGE_Y names the pass's page again, for
            # the rest of the wait and the trade in the blank (Paint's rt_paint_flip).
            #
            # The handler's commands stay in the list (Runtime::DrawList) until the next pass ends: the other
            # page is the one on the screen until the blank, and drawing on it now would show for the rest of
            # the frame. So the list is held back while the timers run: a full one goes on into a region of its
            # own rather than being sent, and one the list is sent for at once is left in it (DrawList::HELD_BACK).
            # Only a handler that fills that region too sends some of its drawing before the blank.
            #
            # Sprites over the picture (+shown_by+ Paint's rt_paint_sprites_shown) are placed at the page trade too,
            # from the numbers the pass finished with, before the timers run (Reference#advance_frame): what a
            # handler moves shows a frame later. So they are placed here, and Paint's routine places none again.
            #
            # rt_painted_pages_up: v0 = 1 while a painted screen of two pages is up, and nought on one page or
            # on a screen drawn from tiles (+crosses+, Tiles::TILES_UP), which is drawn whole after the timers.
            def emit_ticks_on_next_page(asm, memory, crosses, shown_by)
              at = ->(name) { Runtime.at(memory, name) }
              asm.label("rt_wait_ticks_on_next_page")
              asm.jal(Lowering::Picture::SPRITES_OVER_PICTURE) if shown_by == "rt_paint_sprites_shown"
              asm.jal("rt_draw_list_finish")
              emit_page_traded(asm, at)
              DrawList.emit_held_back_open(asm, memory)
              # The passes ended so far, kept to find a wait inside the timers; and the pass's show owed to one.
              show_owed = show_owed_place(memory)
              asm.lw(:t0, at.call(PASSES), :gp)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:t0, 0, :sp)
              asm.li(:t0, 1)
              asm.lui(:t1, show_owed.high)
              asm.sw(:t0, show_owed.low, :t1)
              asm.jal("rt_frame_begins_unless_last")
              asm.lui(:t1, show_owed.high)
              asm.sw(:zero, show_owed.low, :t1)
              DrawList.emit_held_back_close(asm, memory)
              # A wait inside the timers showed this pass's page, ended a pass of its own and took its buttons, as
              # the interpreter's boundary inside the timers does (Reference#advance_frame): this boundary is over.
              asm.lw(:t0, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.lw(:t1, at.call(PASSES), :gp)
              asm.bne(:t0, :t1, "rt_wait_return")
              emit_page_traded(asm, at)
              asm.b("rt_wait_published")

              asm.label("rt_painted_pages_up")
              asm.lw(:v0, at.call(Paint::PAGED), :gp)
              return asm.jr(:ra) unless crosses

              asm.lw(:t0, at.call(Tiles::TILES_UP), :gp)
              asm.sltiu(:t0, :t0, 1)
              asm.jr(:ra) { asm.and(:v0, :v0, :t0) }
            end

            # A wait inside the timers shows the pass's page first. The interpreter shows a tear-free screen's page
            # at the frame boundary before the timers run (Reference#advance_frame), so a handler that waits ends a
            # frame of its own after that one: the pass's page is shown, then the handler's. Here the timers run
            # before the blank that shows the pass's page, so a wait inside them (SHOW_OWED, set while they run)
            # first ends the pass as a wait does, without the game being found waiting, since the interpreter
            # reports no moment there either: the page shown at the next blank, the frames it took and its
            # buttons taken, and its sound moved on. Only then is the page the handler drew on hidden, and its
            # commands, held back meanwhile (DrawList::HELD_BACK), drawn as its own pass ends. The boundary whose
            # timers waited ends with them (#emit_ticks_on_next_page).
            #
            # A screen shown from pages of its own (+shown_by+) copies the page to show it, which is drawing: the
            # handler's list is parked while it does (DrawList#emit_park).
            def emit_show_owed(asm, memory, sound, shown_by)
              at = ->(name) { Runtime.at(memory, name) }
              show_owed = show_owed_place(memory)
              asm.label("rt_wait_show_owed")
              asm.sw(:zero, show_owed.low, :t1)
              asm.jal("rt_draw_list_park") if shown_by
              emit_page_traded(asm, at)
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.sw(:t0, at.call(Paint::PASS_PAGE_Y), :gp)
              if shown_by
                asm.li(:a1, 1)
                asm.jal(shown_by) { asm.move(:a0, :t0) }
              end
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(Paint::FLIP_OWED), :gp)
              emit_end_lines_store(asm, at)
              asm.jal("rt_show_pass")
              asm.lw(:t0, at.call(HOLD), :gp)
              asm.bne(:t0, :zero, "rt_stopped")
              asm.jal("rt_pad_await")
              asm.jal("rt_read_buttons")
              asm.jal("rt_sound_frame") if sound
              asm.jal("rt_draw_list_unpark") if shown_by
              asm.b("rt_wait_owed_shown")
            end

            # SHOW_OWED, as an instruction reaches it from a register given its top half.
            def show_owed_place(memory) = DrawList::StatePlace.for_address(memory[SHOW_OWED])

            # PAGE_Y names the other page.
            def emit_page_traded(asm, at)
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.xori(:t0, :t0, Paint::SECOND_PAGE_TOP_LINE)
              asm.sw(:t0, at.call(Paint::PAGE_Y), :gp)
            end

            # The moment the pass ends: END_LINES for it, the lines since the last blank began, and VBLANK
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
            # The frames are counted from the picture coming on. Setting up takes frames of the console's
            # time with nothing to see, and the interpreter's first pass takes one: the count starts again
            # as the picture first shows, with that frame as the first, so a game counting frames counts
            # the same ones. +count+ is where a game that reads how many frames it has shown since power-on
            # keeps that count, as #count_place gives it (#emit_setting_up_counted).
            def emit_show_pass(asm, at, count)
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
              emit_setting_up_counted(asm, at, count) if count
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(FRAMES), :gp)
              asm.sw(:t0, at.call(FRAMES_MARK), :gp)
              asm.b("rt_show_pass_shown") { asm.sw(:t0, at.call(DISPLAY_ON), :gp) }
              # VBLANK was cleared where the pass ended (#emit_end_lines_store), or where the game stopped.
              asm.label("rt_show_pass_on")
              asm.jal("rt_sleep_until_vblank_wait")
              asm.label("rt_show_pass_shown")
              # A tear-free screen's pages trade places in the blank, before SHOWN marks the pass as up.
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

            # The frames setting up took, counted all the same, in a game that reads how many frames it has
            # shown since power-on. Such a game counts blanks from near the top of setting up (Boot#emit), so
            # FRAMES holds every blank since, and two of them are not setting up's: the one the boot waits for
            # so the game starts as a frame starts, which ends the frame the program was loaded in, and the one
            # just waited for, which ends the first pass's. (A game that sets up inside the frame it was loaded
            # in reads one on its first pass, seen on emulator frame 2, as an Advance cartridge reads one fewer
            # than the frame its first pass is seen on.) The rest go into the game's count at +count+ now, which
            # the first pass reads only once its wait is over, the frames of the pass itself added after
            # (Lowering#emit_wait_vblank): where the interpreter adds them (Reference#store_frame_counters).
            # SETTING_UP keeps them one more, for a reader of the run. No interrupt comes between: one has
            # just come.
            #
            # The frames before the program's first instruction are not counted, and cannot be: the loader
            # (the BIOS on a console, Beetle's own in the emulator) copies the program in first, and a longer
            # program takes longer to copy.
            def emit_setting_up_counted(asm, at, count)
              asm.lw(:t0, at.call(FRAMES), :gp)
              asm.lw(:t2, *count)
              asm.addiu(:t0, :t0, -1)
              asm.sw(:t0, at.call(SETTING_UP), :gp)
              asm.addiu(:t0, :t0, -1)
              asm.addu(:t2, :t2, :t0)
              asm.sw(:t2, *count)
            end

            # [distance, register] naming the game's place at +address+ in a load or a store: from fp in the
            # scratchpad, where the game keeps its quickest numbers, or from gp.
            def count_place(address)
              fast = Memory.distance_from_scratchpad(address)
              return [fast, :fp] if fast

              distance = Memory.distance_from_base(address) or raise(LoweringError, "the frames since power-on are out of gp's reach")
              [distance, :gp]
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

            # STOPPING. rt_halt stops the game where it is: SHOWN marks that the end is on the screen once the
            # blank after it has come, and the processor goes round a loop from then on, the interrupt still
            # counting frames. Going wrong is the same, with what went wrong written down first (rt_fault,
            # a0 = what went wrong, the list and the numbers already in FAULT).
            #
            # A screen drawn from tiles (+tiles+) is drawn whole as the halting pass's picture first, and
            # shown, as the interpreter places the halting pass's sprites (Reference#place_pass_end_before_halt).
            #
            # A painted screen shown from pages of its own (+shown_by+) shows the page it shows by then copied
            # again, in the colours of the fade in force as it stops, with the sprites over it: on one page the
            # page the stopping pass drew on, and on a tear-free screen the other, which the stopping pass never
            # trades for it.
            def emit_stopping(asm, at, tiles, shown_by)
              asm.label("rt_halt")
              if tiles
                asm.jal("rt_tiles_draw")
                asm.li(:t0, 1)
                asm.sw(:t0, at.call(Paint::FLIP_OWED), :gp)
              end
              asm.li(:t0, HALTED)
              asm.label("rt_stop_with_state")
              asm.sw(:t0, at.call(STATE), :gp)
              asm.jal("rt_draw_list_finish") # what the stopping pass drew, drawn before it is shown
              emit_stopping_page_shown(asm, at, shown_by) if shown_by
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

            # The page a stopping game shows, copied again by Paint's routine +shown_by+: PAGE_Y, or on a
            # tear-free screen the page that is not it.
            def emit_stopping_page_shown(asm, at, shown_by)
              asm.lw(:a0, at.call(Paint::PAGE_Y), :gp)
              asm.lw(:t0, at.call(Paint::PAGED), :gp)
              asm.beq(:t0, :zero, "rt_stop_page_shown")
              asm.xori(:a0, :a0, Paint::SECOND_PAGE_TOP_LINE)
              asm.label("rt_stop_page_shown")
              asm.jal(shown_by) { asm.move(:a1, :zero) } # no page published
            end
          end
        end
      end
    end
  end
end
