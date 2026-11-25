# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # Sound effects on a timer, struck inside the frame. A Genesis game's sound driver keys its effects'
          # notes on as each tick of its own timer comes, part way through a frame, where this runtime
          # otherwise sends every note to the chips as the frame's music plays (Sound's rt_sound_frame). For a
          # game whose effects say `on_timer: true` (IR::Tunes.effect_clock_step) it does the same as such a
          # driver.
          #
          # ### Who decides, and when the chips are told
          #
          # The processor still plays the effects a frame at a time, ticks counted as every player counts
          # them, so the sound log, who holds which voice and which note plays are the interpreter's. While a
          # tick's pass over the effects plays (STRIKING), each write it asks of a chip (a PSG byte or two, an
          # FM register) is not made but put on a list (rt_strikes_chip) with the line of the screen it is due
          # on (DUE): the line the frame's clock started on (BASE), plus the part of the frame the tick comes
          # after. So a note and the rest after it in one frame each reach the voice at their own tick, and a
          # voice still sounding the note before keeps its pitch and loudness until then. What the runtime
          # keeps of each voice (its loudness, its fade) moves on at once, as before; only the chips are told
          # later.
          #
          # Every write of the chips goes through rt_strikes_chip in such a game, so a write asked for outside
          # a tick's pass while the list holds something (a fade stepped, a wobble, the tune's own note) is
          # folded into the latest listed write of the same register, which takes its value and waits for the
          # strike; with none listed, it is made now. A new note's loudness waits on the list for its strike,
          # so a fade stepped at the frame's end would otherwise be heard on the note still sounding, and be
          # undone as the strike came. The FM chip's key register keys a voice on or off by its value, so its
          # writes fold by the voice they name.
          #
          # The game's own sound is not folded: it is made now, and drops every listed write of the registers
          # it writes (GAME_SOUND), so the voice keeps it as the interpreter's does (IR::Tunes, "The game's own
          # sound against a listed strike").
          #
          # ### The line interrupt as the clock
          #
          # The video chip can raise an interrupt every so many lines of the screen it draws: its line
          # counter is loaded from register $0A, counts down a line at a time while the screen is drawn, and
          # raises the interrupt as it passes nought, loaded again from the register (plutiedev, "Horizontal
          # interrupts"). The counter counts lines it draws, not the blank's: through the blank it is loaded
          # on every line and raises nothing. And the register can be written only where nothing else is
          # talking to the video chip, since a register write also sets the address the chip writes to next,
          # which the game may be in the middle of using; so it is written once, as the console starts, for
          # an interrupt every STRIDE lines, and the interrupt itself writes nothing to the chip but reads its
          # counter of the line it is drawing (VDP_COUNTER's high byte). The chip is told to raise the
          # interrupt when the list first holds something, and to stop when it is empty as a frame's music
          # begins, both from the game's side (HINT_ON).
          #
          # The lines are counted from power-on in LINE_CLOCK: the blank's interrupt adds a frame's lines as
          # each blank begins, so a line drawn is LINE_CLOCK plus BLANK_LINES plus the counter. The line
          # interrupt (rt_strikes_line) does every entry whose line has come, oldest first. A tick that falls
          # in the blank, where no line interrupt comes, is struck by the blank's interrupt as the blank begins
          # when its line is in the blank's first BLANK_SPLIT lines, and by the first line interrupt after it
          # otherwise: whichever is nearer. Every NTSC console draws LINES_A_FRAME lines a frame.
          #
          # The frame's clock starts as the screen starts to be drawn after the blank the music's pass waited
          # for, BLANK_LINES on from the blank: the pass's music is played in the blank, so its first tick is
          # still to come when it is listed. A pass that took several frames plays their music one after
          # another as its wait ends; the frames after the first start a frame after the one before, so their
          # notes are struck their ticks apart from when they are listed, as late as all else such a game
          # shows. Whatever is due already when the music has played is struck then.
          #
          # ### The sound processor
          #
          # In a game that plays recordings the FM chip is the Z80's, and a write of it is an entry in its
          # queue (Sound#emit_fm_write_queued), which it makes between two samples: the strike queues it at
          # its line. A recording itself, and the FM writes that come with it, start as the frame's music
          # plays, as before (rt_fm_unlisted).
          #
          # ### What it costs
          #
          # Nothing for a game without the word. With it, a frame works out where each tick falls (a multiply
          # and a divide), each write a tick asks for is an entry, and while the list holds something the line
          # interrupt comes every STRIDE lines, each time a read of the chip's counter and a compare when
          # nothing is due.
          module Strikes
            STRIKING = "rt strikes striking" # 1 while a tick's pass over the effects plays
            DUE = "rt strikes due" # The line the pass's writes are due on
            REMAINING = "rt strikes remaining" # The 65536ths of a tick the effects' count had to go to the tick playing, a long
            BASE = "rt strikes base" # The line the frame playing's clock started on
            BLANK_CLOCK = "rt strikes blank clock" # LINE_CLOCK as the pass's wait ended
            LINE_CLOCK = "rt strikes line clock" # The line the last blank began on, counted from power-on
            HINT_ON = "rt strikes hint on" # 1 while the video chip raises the line interrupt
            # The line of the screen being drawn, as the video chip counts it, from which the oldest entry is due:
            # nought when it is due already, and NEVER when the list is empty or it is not due on the screen
            # being drawn. What the line interrupt compares before anything else.
            NEXT_LINE = "rt strikes next line"
            NEVER = 0xFFFF
            LIST = "rt strikes list" # A ring of entries: [what, first, second, the line it is due on], a word each
            HEAD = "rt strikes head" # The oldest entry, as a distance into LIST
            TAIL = "rt strikes tail" # Where the next goes
            ENTRY_BYTES = 8
            ENTRIES = 256
            LIST_MASK = (ENTRIES * ENTRY_BYTES) - 1
            # An entry's first word names the register it writes, so a fold finds it: for the PSG its top bit
            # and the command byte's voice and kind (FIRST_PSG_BITS); for the FM chip the register, or, for
            # its key register, KEY_VOICE and the voice the value keys.
            PSG = 0x8000
            FIRST_PSG_BITS = 0xF0
            KEY_VOICE = 0x1000
            KEY_VOICE_BITS = 7
            # What a dropped entry names: no register, so striking it writes nothing.
            DROPPED = 0x7FFF
            # 1 while the game's own sound (`beep`, `noise`, `wave`, `stop_wave`) is written: each write then
            # drops every listed write of the same register and is made now (IR::Tunes, "The game's own sound
            # against a listed strike").
            GAME_SOUND = "rt strikes game sound"

            LINES_A_FRAME = 262
            DRAWN_LINES = 224
            BLANK_LINES = LINES_A_FRAME - DRAWN_LINES
            STRIDE = 8
            BLANK_SPLIT = (BLANK_LINES + STRIDE) / 2
            # The video chip's counter's top byte from the first line of the blank on.
            BLANK_COUNTER = 0xE0
            # Mode register 1 with the line interrupt on, and off (Console::GenesisHardware::MODE1_NORMAL).
            LINE_INTERRUPT_BIT = 0x10
            # The 68000's interrupt mask at the line interrupt's level, four (the blank's is six).
            LINE_INTERRUPT_MASK = 0x0400

            module_function

            # Whether a game strikes its sound effects inside the frame: one with songs whose effects are on
            # a timer.
            def wanted?(program)
              Lowering::Sound.songs?(program) && IR::Tunes.effects(program).any? &&
                !IR::Tunes.effect_clock_step(program, program.described_console).nil?
            end

            def reserve(memory)
              [STRIKING, DUE, BASE, BLANK_CLOCK, LINE_CLOCK, HINT_ON, NEXT_LINE, HEAD, TAIL, GAME_SOUND].each { |name| memory.reserve(name, 2) }
              memory.reserve(REMAINING, 4)
              memory.reserve(LIST, ENTRIES * ENTRY_BYTES)
              memory.reserve(Recordings::FM_KEPT, Recordings::FM_REGISTERS * 2)
            end

            def strikes?(memory) = memory.reserved?(LIST)

            # The video register writes that switch the line interrupt on and off, and set its stride.
            def mode1_word(on)
              h = Console::GenesisHardware
              h::VDP_REGISTER | (h::REG_MODE1 << 8) | h::MODE1_NORMAL | (on ? LINE_INTERRUPT_BIT : 0)
            end

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_unkept(asm, at)
              emit_game_sound(asm, at)
              emit_chip(asm, at)
              emit_due(asm, at)
              emit_line(asm, at)
              emit_quiet(asm, at)
            end

            # rt_strikes_unkept: no FM register's value kept yet (Recordings::FM_KEPT), as the sound is switched
            # on in a game that plays no recording. A write that changes nothing is dropped before it is listed
            # (Sound#emit_fm_unchanged_dropped): a note sets its voice's every register, some thirty, and only a
            # few change from note to note, so most of a note's entries would be writes of what is there.
            def emit_unkept(asm, at)
              asm.label("rt_strikes_unkept")
              asm.lea(at.call(Recordings::FM_KEPT), asm.a(0))
              asm.move(:w, asm.imm(Recordings::FM_REGISTERS - 1), asm.d(0))
              asm.label("rt_strikes_unkept_next")
              asm.move(:w, asm.imm(Recordings::NOT_KEPT), asm.post(0))
              asm.dbra(asm.d(0), "rt_strikes_unkept_next")
              asm.rts
            end

            # rt_strikes_game_sound(D0 = 1 or 0): GAME_SOUND set, around the game's own sound.
            def emit_game_sound(asm, at)
              asm.label("rt_strikes_game_sound")
              asm.move(:w, asm.d(0), at.call(GAME_SOUND))
              asm.rts
            end

            # rt_strikes_chip(D0, D1, D2 = what the entry names, PSG or FM): a chip's write, from rt_psg_write,
            # rt_sound_volume or rt_fm_write once the sound is on. In a tick's pass it goes on the list, due on
            # DUE, and the line interrupt is switched on; outside one, folded into the latest listed write of
            # the same register, or made now. Made now, too, when the list is full. With the interrupts held
            # off; D0 to D3 and A1 are used, as the chips' own routines use them.
            def emit_chip(asm, at)
              asm.label("rt_strikes_chip")
              asm.movem_push(:l, :d4, :d5, :a0)
              asm.move_from_sr(asm.pre(M68000::SP))
              asm.ori_to_sr(Frame::INTERRUPTS_OFF_BITS)
              asm.tst(:w, at.call(STRIKING))
              asm.branch(:eq, "rt_strikes_chip_fold")
              asm.move(:w, at.call(TAIL), asm.d(4))
              asm.move(:w, asm.d(4), asm.d(5))
              asm.addq(:w, ENTRY_BYTES, asm.d(5))
              asm.and(:w, asm.imm(LIST_MASK), asm.d(5))
              asm.cmp(:w, at.call(HEAD), asm.d(5))
              asm.branch(:eq, "rt_strikes_chip_now")
              asm.lea(at.call(LIST), asm.a(0))
              asm.lea(asm.idx(0, 0, 4, :w), asm.a(0))
              asm.move(:w, asm.d(2), asm.post(0))
              asm.move(:w, asm.d(0), asm.post(0))
              asm.move(:w, asm.d(1), asm.post(0))
              asm.move(:w, at.call(DUE), asm.ind(0))
              asm.move(:w, asm.d(5), at.call(TAIL))
              asm.cmp(:w, at.call(HEAD), asm.d(4))
              asm.branch(:ne, "rt_strikes_chip_listed")
              asm.jsr(asm.abs_l("rt_strikes_next_line")) # the list was empty: this is the oldest
              asm.label("rt_strikes_chip_listed")
              # The line interrupt let in again where it struck the list empty earlier in this frame's music
              # (#emit_line): the status register kept on the stack, at the line interrupt's mask, taken to nought.
              asm.move(:w, asm.ind(M68000::SP), asm.d(4))
              asm.and(:w, asm.imm(Frame::INTERRUPTS_OFF_BITS), asm.d(4))
              asm.cmp(:w, asm.imm(LINE_INTERRUPT_MASK), asm.d(4))
              asm.branch(:ne, "rt_strikes_chip_let_in")
              asm.and(:w, asm.imm(~Frame::INTERRUPTS_OFF_BITS & 0xFFFF), asm.ind(M68000::SP))
              asm.label("rt_strikes_chip_let_in")
              asm.tst(:w, at.call(HINT_ON))
              asm.branch(:ne, "rt_strikes_chip_done")
              asm.move(:w, asm.imm(1), at.call(HINT_ON))
              asm.move(:w, asm.imm(mode1_word(true)), asm.abs_l(Console::GenesisHardware::VDP_CONTROL))
              asm.bra("rt_strikes_chip_done")

              asm.label("rt_strikes_chip_fold")
              asm.move(:w, at.call(HEAD), asm.d(4))
              asm.move(:w, at.call(TAIL), asm.d(5))
              asm.cmp(:w, asm.d(4), asm.d(5))
              asm.branch(:eq, "rt_strikes_chip_now")
              asm.lea(at.call(LIST), asm.a(1))
              asm.tst(:w, at.call(GAME_SOUND))
              asm.branch(:ne, "rt_strikes_chip_drop")
              asm.movea(:l, asm.imm(0), asm.a(0)) # the latest of the same register, once found
              asm.label("rt_strikes_chip_look")
              asm.cmp(:w, asm.idx(1, 0, 4, :w), asm.d(2))
              asm.branch(:ne, "rt_strikes_chip_other")
              asm.lea(asm.idx(1, 0, 4, :w), asm.a(0))
              asm.label("rt_strikes_chip_other")
              asm.addq(:w, ENTRY_BYTES, asm.d(4))
              asm.and(:w, asm.imm(LIST_MASK), asm.d(4))
              asm.cmp(:w, asm.d(4), asm.d(5))
              asm.branch(:ne, "rt_strikes_chip_look")
              asm.move(:l, asm.a(0), asm.d(4))
              asm.branch(:eq, "rt_strikes_chip_now")
              asm.move(:w, asm.d(0), asm.disp(0, 2))
              asm.move(:w, asm.d(1), asm.disp(0, 4))
              asm.bra("rt_strikes_chip_done")

              # The game's own sound: every listed write of the same register dropped, and this one made now.
              asm.label("rt_strikes_chip_drop")
              asm.cmp(:w, asm.idx(1, 0, 4, :w), asm.d(2))
              asm.branch(:ne, "rt_strikes_chip_kept")
              asm.lea(asm.idx(1, 0, 4, :w), asm.a(0))
              asm.move(:w, asm.imm(DROPPED), asm.ind(0))
              asm.label("rt_strikes_chip_kept")
              asm.addq(:w, ENTRY_BYTES, asm.d(4))
              asm.and(:w, asm.imm(LIST_MASK), asm.d(4))
              asm.cmp(:w, asm.d(4), asm.d(5))
              asm.branch(:ne, "rt_strikes_chip_drop")

              asm.label("rt_strikes_chip_now")
              asm.jsr(asm.abs_l("rt_strikes_write"))
              asm.label("rt_strikes_chip_done")
              asm.move_to_sr(asm.post(M68000::SP))
              asm.movem_pop(:l, :d4, :d5, :a0)
              asm.rts

              # rt_strikes_write(D0, D1, D2): the write made, by the chip D2 names; none for a dropped entry.
              asm.label("rt_strikes_write")
              asm.cmp(:w, asm.imm(DROPPED), asm.d(2))
              asm.branch(:ne, "rt_strikes_write_made")
              asm.rts
              asm.label("rt_strikes_write_made")
              asm.tst(:w, asm.d(2))
              asm.branch(:mi, "rt_strikes_write_psg")
              asm.jmp(asm.abs_l("rt_fm_now"))
              asm.label("rt_strikes_write_psg")
              asm.jmp(asm.abs_l("rt_psg_now"))
            end

            # rt_strikes_due(D6 = the line now): every entry whose line has come made, oldest first. Uses D0 to
            # D5, A0 and A1; called with the interrupts held off. An entry leaves the list once it is made, not
            # before, so a reader of the run who stops the console in the middle of one finds it still listed
            # (HeadlessRun#chip_registers_after_strikes).
            def emit_due(asm, at)
              asm.label("rt_strikes_due")
              asm.move(:w, at.call(HEAD), asm.d(4))
              asm.cmp(:w, at.call(TAIL), asm.d(4))
              asm.branch(:eq, "rt_strikes_due_done")
              asm.lea(at.call(LIST), asm.a(0))
              asm.lea(asm.idx(0, 0, 4, :w), asm.a(0))
              asm.move(:w, asm.d(6), asm.d(5))
              asm.sub(:w, asm.disp(0, 6), asm.d(5))
              asm.branch(:mi, "rt_strikes_due_done") # its line still to come
              asm.move(:w, asm.ind(0), asm.d(2))
              asm.move(:w, asm.disp(0, 2), asm.d(0))
              asm.move(:w, asm.disp(0, 4), asm.d(1))
              asm.jsr(asm.abs_l("rt_strikes_write"))
              asm.addq(:w, ENTRY_BYTES, asm.d(4))
              asm.and(:w, asm.imm(LIST_MASK), asm.d(4))
              asm.move(:w, asm.d(4), at.call(HEAD))
              asm.bra("rt_strikes_due")
              asm.label("rt_strikes_due_done")

              # rt_strikes_next_line: NEXT_LINE worked out for the oldest entry, against the screen LINE_CLOCK's
              # blank goes on to. Uses D4 and A0.
              asm.label("rt_strikes_next_line")
              asm.move(:w, at.call(HEAD), asm.d(4))
              asm.cmp(:w, at.call(TAIL), asm.d(4))
              asm.branch(:eq, "rt_strikes_next_line_never")
              asm.lea(at.call(LIST), asm.a(0))
              asm.move(:w, asm.idx(0, 6, 4, :w), asm.d(4))
              asm.sub(:w, at.call(LINE_CLOCK), asm.d(4))
              asm.sub(:w, asm.imm(BLANK_LINES), asm.d(4))
              asm.branch(:pl, "rt_strikes_next_line_ahead")
              asm.moveq(0, asm.d(4)) # due already
              asm.label("rt_strikes_next_line_ahead")
              asm.cmp(:w, asm.imm(DRAWN_LINES), asm.d(4))
              asm.branch(:cs, "rt_strikes_next_line_set")
              asm.label("rt_strikes_next_line_never")
              asm.move(:w, asm.imm(NEVER), asm.d(4))
              asm.label("rt_strikes_next_line_set")
              asm.move(:w, asm.d(4), at.call(NEXT_LINE))
              asm.rts

              # rt_strikes_now: D6 = the line the chip is drawing, from LINE_CLOCK. In the blank the counter
              # is counted from its first line, which comes to fewer lines than have gone by in its second part,
              # where the counter goes back (an NTSC chip counts $E0 to $EA, then $E5 to $FF): never a line
              # still to come. Before the blank's interrupt has added the frame, it is the frame before's.
              asm.label("rt_strikes_now")
              asm.moveq(0, asm.d(6))
              asm.move(:b, asm.abs_l(Console::GenesisHardware::VDP_COUNTER), asm.d(6))
              asm.cmp(:w, asm.imm(BLANK_COUNTER), asm.d(6))
              asm.branch(:cc, "rt_strikes_now_blank")
              asm.add(:w, asm.imm(BLANK_LINES), asm.d(6))
              asm.add(:w, at.call(LINE_CLOCK), asm.d(6))
              asm.rts
              asm.label("rt_strikes_now_blank")
              asm.sub(:w, asm.imm(BLANK_COUNTER), asm.d(6))
              asm.add(:w, at.call(LINE_CLOCK), asm.d(6))
              asm.rts
            end

            # rt_strikes_line: the line interrupt. Most of the time nothing is due, and all it does is read the
            # chip's counter and compare it with NEXT_LINE. Every register it uses is kept; the blank's
            # interrupt is held off while the list is read, since it strikes too. Once the list is empty the
            # game goes on with the line interrupt held off (its status register's mask, kept on the stack,
            # raised to the line interrupt's level), since nothing is left to strike until the next frame's
            # music, which comes after a wait that lets it in again (Frame's rt_sleep_until_vblank).
            def emit_line(asm, at)
              asm.label("rt_strikes_line")
              asm.move(:w, asm.d(0), asm.pre(M68000::SP))
              asm.moveq(0, asm.d(0))
              asm.move(:b, asm.abs_l(Console::GenesisHardware::VDP_COUNTER), asm.d(0))
              asm.cmp(:w, at.call(NEXT_LINE), asm.d(0))
              asm.branch(:cc, "rt_strikes_line_due")
              asm.move(:w, asm.post(M68000::SP), asm.d(0))
              asm.rte
              asm.label("rt_strikes_line_due")
              asm.move(:w, asm.post(M68000::SP), asm.d(0))
              asm.ori_to_sr(Frame::INTERRUPTS_OFF_BITS)
              asm.movem_push(:l, :d0, :d1, :d2, :d3, :d4, :d5, :d6, :a0, :a1)
              asm.jsr(asm.abs_l("rt_strikes_now"))
              asm.jsr(asm.abs_l("rt_strikes_due"))
              asm.move(:w, at.call(HEAD), asm.d(0))
              asm.cmp(:w, at.call(TAIL), asm.d(0))
              asm.movem_pop(:l, :d0, :d1, :d2, :d3, :d4, :d5, :d6, :a0, :a1) # the flags are the compare's
              asm.branch(:ne, "rt_strikes_line_done")
              asm.or(:w, asm.imm(LINE_INTERRUPT_MASK), asm.ind(M68000::SP))
              asm.label("rt_strikes_line_done")
              asm.rte
            end

            # rt_strikes_quiet: the line interrupt switched off when nothing is listed, from the game's side,
            # where the video chip may be told: as the pass waits, and as a frame's music begins. Uses D0.
            def emit_quiet(asm, at)
              asm.label("rt_strikes_quiet")
              asm.tst(:w, at.call(HINT_ON))
              asm.branch(:eq, "rt_strikes_quiet_done")
              asm.move(:w, at.call(HEAD), asm.d(0))
              asm.cmp(:w, at.call(TAIL), asm.d(0))
              asm.branch(:ne, "rt_strikes_quiet_done")
              asm.clr(:w, at.call(HINT_ON))
              asm.move(:w, asm.imm(mode1_word(false)), asm.abs_l(Console::GenesisHardware::VDP_CONTROL))
              asm.label("rt_strikes_quiet_done")
              asm.rts
            end

            # In the blank's interrupt, inline, once the frame is counted: a frame's lines on the clock, and the
            # entries due in the blank's first BLANK_SPLIT lines struck. Every register it uses is kept.
            # NEXT_LINE is worked out again for the screen the blank goes on to (rt_strikes_due does it).
            def emit_blank(asm, at)
              asm.add(:w, asm.imm(LINES_A_FRAME), at.call(LINE_CLOCK))
              asm.move(:w, at.call(HEAD), asm.d(0))
              asm.cmp(:w, at.call(TAIL), asm.d(0))
              asm.branch(:eq, "rt_strikes_blank_done")
              asm.movem_push(:l, :d4, :d5, :d6, :a0, :a1)
              asm.move(:w, at.call(LINE_CLOCK), asm.d(6))
              asm.add(:w, asm.imm(BLANK_SPLIT), asm.d(6))
              asm.jsr(asm.abs_l("rt_strikes_due"))
              asm.movem_pop(:l, :d4, :d5, :d6, :a0, :a1)
              asm.label("rt_strikes_blank_done")
            end

            # --- where the music works out when ---

            # As a pass's music begins, inline: LINE_CLOCK kept as the wait ended.
            def emit_wait_ended(asm, at) = asm.move(:w, at.call(LINE_CLOCK), at.call(BLANK_CLOCK))

            # As a frame of the music begins, inline: BASE, the first line drawn after the blank the pass
            # waited for, and a frame more for each frame of the pass played before this one; REMAINING, what
            # the effects' count (+clock+) has to go to its first tick, before it moves on; and the line
            # interrupt switched off when nothing is listed.
            def emit_set_frame_base(asm, at, clock)
              asm.move(:w, at.call(Frame::FRAMES_TAKEN), asm.d(0))
              asm.sub(:w, at.call(Sound::TICKS_LEFT), asm.d(0))
              asm.mulu(asm.imm(LINES_A_FRAME), asm.d(0))
              asm.add(:w, at.call(BLANK_CLOCK), asm.d(0))
              asm.add(:w, asm.imm(BLANK_LINES), asm.d(0))
              asm.move(:w, asm.d(0), at.call(BASE))
              asm.moveq(0, asm.d(0))
              asm.move(:w, at.call(clock), asm.d(0))
              asm.neg(:l, asm.d(0))
              asm.add(:l, asm.imm(0x10000), asm.d(0))
              asm.move(:l, asm.d(0), at.call(REMAINING))
              asm.jsr(asm.abs_l("rt_strikes_quiet"))
            end

            # A tick's pass is about to play, inline: DUE, BASE plus REMAINING's share of the frame's lines
            # (+step+ is a frame's 65536ths, IR::Tunes.effect_clock_step), and STRIKING on. Both are cut to
            # sixteenths so the multiply and the divide take words: REMAINING is at most eight ticks.
            def emit_striking_on(asm, at, step)
              asm.move(:l, at.call(REMAINING), asm.d(0))
              asm.lsr(:l, 4, asm.d(0))
              asm.mulu(asm.imm(LINES_A_FRAME), asm.d(0))
              asm.divu(asm.imm(step >> 4), asm.d(0))
              asm.add(:w, at.call(BASE), asm.d(0))
              asm.move(:w, asm.d(0), at.call(DUE))
              asm.move(:w, asm.imm(1), at.call(STRIKING))
            end

            # ...and played, inline: STRIKING off.
            def emit_striking_off(asm, at) = asm.clr(:w, at.call(STRIKING))

            # The next tick of the frame, inline: a whole count further to go.
            def emit_next_tick(asm, at) = asm.add(:l, asm.imm(0x10000), at.call(REMAINING))

            # Once a frame's music has played, inline: what is due already struck, with the interrupts held off.
            def emit_due_now(asm)
              asm.move_from_sr(asm.pre(M68000::SP))
              asm.ori_to_sr(Frame::INTERRUPTS_OFF_BITS)
              asm.jsr(asm.abs_l("rt_strikes_now"))
              asm.jsr(asm.abs_l("rt_strikes_due"))
              asm.move_to_sr(asm.post(M68000::SP))
            end
          end
        end
      end
    end
  end
end
