# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Sound effects on a timer, struck inside the frame. A cartridge's sound driver that counts
        # its effects' ticks on a timer of its own writes each note to the sound chip as its tick
        # comes, part way through a frame, where the player here writes every note as the frame
        # begins. For a game whose effects say `on_timer: true` (IR::Tunes.effect_clock_step) it does
        # the same as such a driver.
        #
        # ### Who decides, and when the chip is told
        #
        # The screen's interrupt still plays the effects a frame at a time, ticks counted as every
        # player counts them, so who holds which voice and which note plays are the interpreter's.
        # While a tick's pass over the effects plays, each register write it makes is not done but put
        # on a list (PUT) with the line of the screen it is due on: the part of the frame the tick
        # comes after, counted in lines from the start of the blank, where the frame's music begins. A
        # line is 1232 cycles, some 73 microseconds (GBATEK, "LCD Dimensions and Timings"), so a note
        # lands within a line of its tick. What the player keeps of each voice (who holds it, its
        # wobble, its shapes) moves on at once, as before; only the chip is told later.
        #
        # ### The alarm
        #
        # Nothing on the console raises an interrupt at a chosen moment but a timer running out or the
        # display reaching a chosen line. So the list's first entry sets one of those going (DUE), and
        # its interrupt does every entry that has come and sets it going again for the next:
        #
        # - a hardware timer of the four, counting at the CPU's clock over 1024, 16384 times a
        #   second, started from 65536 less the time to go so it runs out then and interrupts (GBATEK,
        #   "GBA Timers"); taken after the game's own timers and the mixer's;
        # - where the game holds every timer, the display's line match: the line to interrupt at,
        #   written to DISPSTAT's top byte (GBATEK, "LCD I/O Interrupts and Status");
        # - where the mix of recordings holds that too (Mixer, at the first line), nothing: the
        #   notes are written as their pass plays, at the start of the frame, as in a game with no
        #   timer.
        #
        # Everything that reads or writes the list runs inside the screen's interrupt or another
        # interrupt, which the console never lets in while one is running, so the list needs no lock.
        # The one cost of that is the mix of recordings, which runs in an interrupt for much of the
        # frame: an alarm that comes while it runs would wait for it to finish, longer the more
        # recordings sound at once. So the mix looks for the alarm between voices and answers it there
        # (#emit_alarm_polled).
        #
        # ### Writes at the frame boundary
        #
        # Each frame ends with a wobbling note's pitch and a stepping note's shape written to their
        # voices (Audio#emit_step_wobbles, #emit_step_shapes). Written at once, the note still sounding
        # before a listed strike would take the new note's pitch or shape early. So such a write is
        # folded into the latest listed write of the same register (FOLD_PITCH, FOLD_SHAPE), which
        # then strikes the note with them, and only written now when nothing of that register is
        # listed. Leftovers from a frame are written as the next one's music begins (FLUSH), before
        # its own are listed.
        #
        # ### What it costs
        #
        # Nothing for a game without the word. With it, a tick's pass costs a multiply for its line,
        # each write a call and two stores, and later an interrupt for each line that has any.
        class EffectStrikes
          include Console::Hardware

          PUT = :__strikes_put # r0 the value, r1 the register: onto the list, due on DUE
          DUE = :__strikes_due # every entry whose line has come written, and the alarm set for the next
          FLUSH = :__strikes_flush # every entry written now
          FOLD_PITCH = :__strikes_fold_pitch # r0 a pitch without its start bit, r1 the register
          FOLD_SHAPE = :__strikes_fold_shape # r0 a control register's low byte, r1 the register
          FOLD_SPEAKERS = :__strikes_fold_speakers # r0 speaker switches to clear above the ones to set
          DROP_VOICE = :__strikes_drop_voice # r0 a voice's first register's distance, r1 its speaker switches
          AFTER_VOICE = :__strikes_after_voice # r0 the value, r1 the register's address: after what the voice has listed

          DUE_LINE = :__strikes_due_line # The line, from the start of the blank, a tick's writes are due on
          REMAINING = :__strikes_remaining # The 65536ths of a tick the effects' count had to go to the tick playing
          HEAD = :__strikes_head # The oldest entry, as a distance into the list
          TAIL = :__strikes_tail # Where the next goes

          # An entry is two words: the line it is due on above the register's distance from the
          # I/O registers' start, and the value. A distance of nought is a waveform to put in the
          # wave voice, the value its place in the score; SOUNDCNT_L's is the speaker switches of
          # one voice, the switches to clear above the ones to set.
          ENTRY_BYTES = 8
          ENTRIES = 64
          LIST_BYTES = ENTRIES * ENTRY_BYTES
          LIST_BITS = LIST_BYTES.bit_length - 1 # A place in the list is kept to these low bits
          WAVEFORM = 0
          IO_START = 0x0400_0000
          SPEAKERS = REG_SOUNDCNT_L - IO_START

          LINES_A_FRAME = 228
          BLANK_LINE = 160 # The line the blank starts on: the frame's music starts there
          # A line is 1232 cycles and the timer counts 1024 of them: 77 of its counts are 64 lines.
          COUNTS_PER_64_LINES = 77
          TIMER_PRESCALER_1024 = 0x0003
          LR = 14
          PC = 15

          # How much roomy memory the list takes, for the build's memory check (Roomy.reserved_by_build),
          # given the effects' song nodes (Audio.effect_songs): nought unless they are on a timer.
          def self.list_bytes(effect_songs) = effect_songs.any?(&:timer_rate) ? LIST_BYTES : 0

          # +step+ is the effects' count's step a frame (IR::Tunes.effect_clock_step); +timer+ the
          # hardware timer taken for the alarm, or nil; +line_free+ answers whether the line match is
          # free for it, asked once the build knows whether the mix of recordings holds it.
          def initialize(emitter:, primitives:, memory:, step:, timer:, line_free:)
            @emitter = emitter
            @primitives = primitives
            @step = step
            @timer = timer
            @line_free = line_free
            @list = memory.alloc_roomy(LIST_BYTES) ||
                    raise(LoweringError, "There is no room in the roomy memory for the sound effects' strike list.")
          end

          # How the alarm is kept: :timer, :line, or nil when neither is free and the notes are
          # written as their pass plays.
          def alarm
            return :timer if @timer
            return :line if @line_free.call

            nil
          end

          def striking? = !alarm.nil?

          # The interrupt enable bit the alarm raises, or nought.
          def interrupt_bit
            case alarm
            when :timer then IRQ_TIMER0 << @timer
            when :line then IRQ_VCOUNT
            else 0
            end
          end

          # What DISPSTAT announces for the alarm: the line match, for the line's alarm.
          def display_announces = alarm == :line ? DISPSTAT_VCOUNT_IRQ : 0

          # The alarm's interrupt, inline in the dispatcher: the timer stopped, then DUE.
          def emit_alarm_answered
            if alarm == :timer
              @emitter.emit(ASM.load_immediate(TMP, timer_control))
              @emitter.emit(ASM.load_immediate(ACC, 0))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
            @emitter.emit_branch(:bl, DUE)
          end

          # Where ANSWERED runs, as setting up finds it: the mix of recordings, which runs from a copy
          # of its own in the quick memory, calls it through this.
          ANSWERED = :__strikes_answered # the alarm's interrupt acknowledged and answered, outside the dispatcher
          ANSWERED_ADDRESS = :__strikes_answered_address

          # The alarm, looked for between two of the mix's voices (Mixer#between_voices). The mix runs
          # in an interrupt for much of the frame and the console lets no other in while it does, so
          # an alarm that has come is answered here, through ANSWERED_ADDRESS. Uses r0, r1 and r12;
          # keeps lr, which holds where the mix returns to.
          def emit_alarm_polled
            e = @emitter
            quiet = e.gensym
            e.emit(ASM.load_immediate(TMP, REG_IF))
            e.emit(ASM.load_halfword(ACC, TMP))
            e.emit(ASM.tst_imm(ACC, interrupt_bit))
            e.emit_branch(:bcond, quiet, cond: :eq)
            e.emit(ASM.push(LR))
            @primitives.load_var(ACC, ANSWERED_ADDRESS)
            e.emit_call_through(ACC)
            e.emit(ASM.pop(LR))
            e.place_label(quiet)
          end

          # --- in the frame's music ---

          # As the frame's music begins, inline, before the effects' count moves on (+clock+ is the
          # count's variable): what is left of last frame written, and REMAINING, what the count has
          # to go to its first tick.
          def emit_frame_begun(clock)
            @emitter.emit_branch(:bl, FLUSH)
            @primitives.load_var(ACC, clock)
            @emitter.emit(ASM.rsb_imm(ACC, ACC, IR::Tunes::CLOCK_MODULUS))
            @primitives.store_var(ACC, REMAINING)
            emit_due_line
          end

          # The next tick of the frame, inline: a whole count further to go, and its line.
          def emit_next_tick
            @primitives.load_var(ACC, REMAINING)
            @emitter.emit(ASM.add_imm(ACC, ACC, IR::Tunes::CLOCK_MODULUS))
            @primitives.store_var(ACC, REMAINING)
            emit_due_line
          end

          # DUE_LINE: REMAINING's share of the frame's lines, REMAINING × lines ÷ step, as the top word
          # of a multiply by lines × 2^32 ÷ step, since the processor has no divide. A tick that plays
          # is at most a step away, so the line is at most a frame's. Uses r0 to r3.
          def emit_due_line
            @primitives.load_var(3, REMAINING)
            @emitter.emit(ASM.load_immediate(2, (LINES_A_FRAME << 32) / @step))
            @emitter.emit(ASM.umull(ACC, TMP, 3, 2))
            @primitives.store_var(TMP, DUE_LINE)
          end

          # As the frame's music ends, inline: what is due already written, and the alarm set.
          def emit_frame_ended = @emitter.emit_branch(:bl, DUE)

          # --- the routines, inside the screen's interrupt ---

          # +emit_upload_wave+ writes the call that puts the waveform at ACC's place in the score
          # (r2) into the wave voice; nil in a game whose effects play no wave voice.
          def emit_routines(score:, emit_upload_wave:)
            emit_put
            emit_answered
            emit_due(score, emit_upload_wave)
            emit_fold
            emit_fold_speakers
            emit_drop_voice
            emit_after_voice
          end

          # The registers of a voice, as distances from the I/O registers' start: SOUND1CNT_L to
          # SOUND4CNT_H, eight bytes a voice (GBATEK, "GBA Sound Channel 1" to "4"). The wave voice
          # has its wave RAM besides, and the listed waveforms.
          VOICE_REGISTERS = 8
          def self.voice_registers_at(channel) = REG_SOUND1CNT_L - IO_START + ((channel - 1) * VOICE_REGISTERS)
          WAVE_VOICE_AT = 0x70
          WAVE_RAM_AT = 0x90
          WAVE_RAM_BYTES = 16

          private

          def timer_control = REG_TM0CNT_H + (@timer * 4)
          def timer_counter = REG_TM0CNT_L + (@timer * 4)

          # PUT (r0 the value, r1 the register's address): onto the list, due on DUE_LINE. A full
          # list is written out first. Keeps every register but r0, r1 and r12.
          def emit_put
            e = @emitter
            room = e.gensym
            e.place_label(PUT)
            e.emit(ASM.push(2, 3, 4, LR))
            e.place_label(room)
            @primitives.load_var(2, TAIL)
            e.emit(ASM.add_imm(3, 2, ENTRY_BYTES))
            emit_wrap(3)
            @primitives.load_var(4, HEAD)
            e.emit(ASM.cmp_reg(3, 4))
            listed = e.gensym
            e.emit_branch(:bcond, listed, cond: :ne)
            e.emit(ASM.push(ACC, TMP)) # full: everything listed written now, then this listed
            e.emit_branch(:bl, FLUSH)
            e.emit(ASM.pop(ACC, TMP))
            e.emit_branch(:b, room)
            e.place_label(listed)
            @primitives.store_var(3, TAIL)
            e.emit(ASM.load_immediate(4, @list))
            e.emit(ASM.add_reg(4, 4, 2))
            e.emit(ASM.lsl_imm(TMP, TMP, 16))
            e.emit(ASM.lsr_imm(TMP, TMP, 16)) # the register's distance
            @primitives.load_var(3, DUE_LINE)
            e.emit(ASM.orr_reg_lsl(TMP, TMP, 3, 16))
            e.emit(ASM.str(TMP, 4))
            e.emit(ASM.str_offset(ACC, 4, 4))
            e.emit(ASM.pop(2, 3, 4, PC))
          end

          # ANSWERED: the alarm's interrupt acknowledged, so it does not come again, then answered as
          # the dispatcher answers it, on into DUE. Keeps every register but r0, r1 and r12.
          def emit_answered
            @emitter.place_label(ANSWERED)
            @emitter.emit(ASM.load_immediate(TMP, REG_IF))
            @emitter.emit(ASM.load_immediate(ACC, interrupt_bit))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
            if alarm == :timer
              @emitter.emit(ASM.load_immediate(TMP, timer_control))
              @emitter.emit(ASM.load_immediate(ACC, 0))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
            @emitter.emit_branch(:b, DUE)
          end

          # AFTER_VOICE (r0 the value, r1 a voice's register's address), for the tune's note outside a
          # tick's pass: listed after the latest listed write of the same voice, due on that write's
          # line, where the list holds one; otherwise written now. A tune taking back a voice an effect
          # let go of in this frame then starts its note after the effect's listed release, not before
          # it, where the release would silence the tune's note until its next (IR::Tunes, "The game's
          # own sound against a listed strike"). Written now, too, when the list is full. Keeps every
          # register but r0, r1 and r12.
          def emit_after_voice
            e = @emitter
            look, other, looked, now, done = Array.new(5) { e.gensym }
            e.place_label(AFTER_VOICE)
            e.emit(ASM.push(2, 3, 4, 5, 7, LR))
            e.emit(ASM.load_immediate(5, 0)) # where the latest of the voice is, once found
            e.emit(ASM.lsl_imm(4, TMP, 16))
            e.emit(ASM.lsr_imm(4, 4, 19)) # the voice's eight registers, as one number
            @primitives.load_var(2, HEAD)
            @primitives.load_var(3, TAIL)
            e.place_label(look)
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, looked, cond: :eq)
            e.emit(ASM.load_immediate(7, @list))
            e.emit(ASM.add_reg(7, 7, 2))
            e.emit(ASM.ldr(LR, 7))
            e.emit(ASM.lsl_imm(LR, LR, 16))
            e.emit(ASM.cmp_reg_lsr(4, LR, 19))
            e.emit_branch(:bcond, other, cond: :ne)
            e.emit(ASM.mov_reg(5, 7))
            e.place_label(other)
            e.emit(ASM.add_imm(2, 2, ENTRY_BYTES))
            emit_wrap(2)
            e.emit_branch(:b, look)

            e.place_label(looked)
            e.emit(ASM.cmp_imm(5, 0))
            e.emit_branch(:bcond, now, cond: :eq)
            e.emit(ASM.ldr(3, 5))
            e.emit(ASM.lsr_imm(3, 3, 16)) # its line
            @primitives.load_var(2, TAIL)
            e.emit(ASM.add_imm(4, 2, ENTRY_BYTES))
            emit_wrap(4)
            @primitives.load_var(5, HEAD)
            e.emit(ASM.cmp_reg(4, 5))
            e.emit_branch(:bcond, now, cond: :eq)
            @primitives.store_var(4, TAIL)
            e.emit(ASM.load_immediate(7, @list))
            e.emit(ASM.add_reg(7, 7, 2))
            e.emit(ASM.lsl_imm(TMP, TMP, 16))
            e.emit(ASM.lsr_imm(TMP, TMP, 16)) # the register's distance
            e.emit(ASM.orr_reg_lsl(TMP, TMP, 3, 16))
            e.emit(ASM.str(TMP, 7))
            e.emit(ASM.str_offset(ACC, 7, 4))
            e.emit_branch(:b, done)
            e.place_label(now)
            e.emit(ASM.store_halfword(ACC, TMP))
            e.place_label(done)
            e.emit(ASM.pop(2, 3, 4, 5, 7, PC))
          end

          # +reg+, a place in the list one entry on, kept inside the list.
          def emit_wrap(reg)
            @emitter.emit(ASM.lsl_imm(reg, reg, 32 - LIST_BITS))
            @emitter.emit(ASM.lsr_imm(reg, reg, 32 - LIST_BITS))
          end

          # FLUSH and DUE: every entry written, oldest first, while its line has come (DUE) or
          # whatever its line (FLUSH); then the alarm set for the next, or stopped. Keeps every
          # register but r0, r1 and r12.
          #
          # In the body: r2 the head, r4 the list, r5 the entry's first word, r6 its place, r7 whether
          # this is FLUSH, r3 the line now.
          def emit_due(score, emit_upload_wave)
            e = @emitter
            body, upcoming, write, speakers, waveform, empty, done = Array.new(7) { e.gensym }
            e.place_label(FLUSH)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.load_immediate(7, 1))
            e.emit_branch(:b, body)
            e.place_label(DUE)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.load_immediate(7, 0))
            e.place_label(body)
            e.emit(ASM.load_immediate(4, @list))
            e.place_label(upcoming)
            @primitives.load_var(2, HEAD)
            @primitives.load_var(3, TAIL)
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, empty, cond: :eq)
            e.emit(ASM.add_reg(6, 4, 2))
            e.emit(ASM.ldr(5, 6))
            e.emit(ASM.cmp_imm(7, 0))
            e.emit_branch(:bcond, write, cond: :ne)
            emit_line_now(3)
            e.emit(ASM.cmp_reg_lsr(3, 5, 16))
            e.emit_branch(:bcond, write, cond: :hs)
            emit_set_alarm(write)
            e.emit_branch(:b, done)

            e.place_label(write)
            e.emit(ASM.add_imm(2, 2, ENTRY_BYTES))
            emit_wrap(2)
            @primitives.store_var(2, HEAD)
            e.emit(ASM.ldr_offset(ACC, 6, 4))
            e.emit(ASM.lsl_imm(TMP, 5, 16))
            e.emit(ASM.lsr_imm(TMP, TMP, 16))
            if emit_upload_wave
              e.emit(ASM.cmp_imm(TMP, WAVEFORM))
              e.emit_branch(:bcond, waveform, cond: :eq)
            end
            e.emit(ASM.cmp_imm(TMP, SPEAKERS))
            e.emit_branch(:bcond, speakers, cond: :eq)
            e.emit(ASM.add_imm(TMP, TMP, IO_START))
            e.emit(ASM.store_halfword(ACC, TMP))
            e.emit_branch(:b, upcoming)

            # One voice's speaker switches, the rest left as they are.
            e.place_label(speakers)
            e.emit(ASM.add_imm(TMP, TMP, IO_START))
            e.emit(ASM.load_halfword(2, TMP))
            e.emit(ASM.lsr_imm(3, ACC, 16))
            e.emit(ASM.bic_reg(2, 2, 3))
            e.emit(ASM.lsl_imm(ACC, ACC, 16))
            e.emit(ASM.orr_reg_lsr(2, 2, ACC, 16))
            e.emit(ASM.store_halfword(2, TMP))
            e.emit_branch(:b, upcoming)

            if emit_upload_wave
              e.place_label(waveform)
              e.emit_load_data_address(2, score)
              emit_upload_wave.call
              e.emit_branch(:b, upcoming)
            end

            e.place_label(empty)
            if alarm == :timer
              e.emit(ASM.load_immediate(TMP, timer_control))
              e.emit(ASM.load_immediate(ACC, 0))
              e.emit(ASM.store_halfword(ACC, TMP))
            end
            e.place_label(done)
            e.emit(ASM.pop(2, 3, 4, 5, 6, 7, PC))
          end

          # +reg+ = the line the display is on, counted from the start of the blank. Uses TMP.
          def emit_line_now(reg)
            @emitter.emit(ASM.load_immediate(TMP, REG_VCOUNT))
            @emitter.emit(ASM.load_halfword(reg, TMP))
            @emitter.emit(ASM.subs_imm(reg, reg, BLANK_LINE))
            @emitter.emit(ASM.add_imm_cond(:lt, reg, reg, LINES_A_FRAME))
          end

          # The alarm set for the entry in r5, whose line (its top half) is still to come; r3 is the
          # line now. The timer runs out after the lines to go, in its counts rounded up, so it never
          # comes early. The line match is the entry's line as the display counts it. A line that went
          # by as it was written would not match again this frame, so the line is read again and the
          # entry written at once (+write+) if it has come.
          def emit_set_alarm(write)
            e = @emitter
            e.emit(ASM.lsr_imm(ACC, 5, 16))
            if alarm == :timer
              e.emit(ASM.sub_reg(ACC, ACC, 3))
              e.emit(ASM.load_immediate(TMP, COUNTS_PER_64_LINES))
              e.emit(ASM.mul(ACC, ACC, TMP))
              e.emit(ASM.add_imm(ACC, ACC, 63))
              e.emit(ASM.lsr_imm(ACC, ACC, 6))
              e.emit(ASM.rsb_imm(ACC, ACC, 0)) # its low half: 65536 less the counts
              e.emit(ASM.load_immediate(TMP, timer_counter))
              e.emit(ASM.load_immediate(3, 0))
              e.emit(ASM.store_halfword_offset(3, TMP, 2)) # stopped, so starting it loads the counter
              e.emit(ASM.store_halfword(ACC, TMP))
              e.emit(ASM.load_immediate(3, TIMER_ENABLE | TIMER_IRQ | TIMER_PRESCALER_1024))
              e.emit(ASM.store_halfword_offset(3, TMP, 2))
            else
              e.emit(ASM.add_imm(ACC, ACC, BLANK_LINE))
              e.emit(ASM.cmp_imm(ACC, LINES_A_FRAME))
              e.emit(ASM.sub_imm_cond(:hs, ACC, ACC, LINES_A_FRAME))
              e.emit(ASM.load_immediate(TMP, REG_DISPSTAT + 1))
              e.emit(ASM.strb(ACC, TMP))
              emit_line_now(3)
              e.emit(ASM.cmp_reg_lsr(3, 5, 16))
              e.emit_branch(:bcond, write, cond: :hs)
            end
          end

          # FOLD_SPEAKERS (r0 the switches to clear above the ones to set, as a listed SPEAKERS entry holds
          # them), for a song's note setting its voice's speakers outside a tick's
          # pass. Where the list holds a speaker write that changes any of those switches, the latest of
          # them takes them in: the listed write would otherwise overtake this later one as it is struck,
          # and leave the voice on the speakers the effect asked for. Otherwise SOUNDCNT_L is changed now.
          # Keeps every register but r0, r1 and r12.
          def emit_fold_speakers
            e = @emitter
            look, other, looked, now, done = Array.new(5) { e.gensym }
            e.place_label(FOLD_SPEAKERS)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.load_immediate(5, 0)) # where the latest is, once found
            e.emit(ASM.lsr_imm(4, ACC, 16)) # the switches to clear
            @primitives.load_var(2, HEAD)
            @primitives.load_var(3, TAIL)
            e.place_label(look)
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, looked, cond: :eq)
            e.emit(ASM.load_immediate(7, @list))
            e.emit(ASM.add_reg(7, 7, 2))
            e.emit(ASM.ldr(LR, 7))
            e.emit(ASM.lsl_imm(LR, LR, 16))
            e.emit(ASM.lsr_imm(LR, LR, 16))
            e.emit(ASM.cmp_imm(LR, SPEAKERS))
            e.emit_branch(:bcond, other, cond: :ne)
            e.emit(ASM.ldr_offset(6, 7, 4))
            e.emit(ASM.lsr_imm(6, 6, 16))
            e.emit(ASM.tst_reg(6, 4))
            e.emit(ASM.mov_reg_cond(:ne, 5, 7))
            e.place_label(other)
            e.emit(ASM.add_imm(2, 2, ENTRY_BYTES))
            emit_wrap(2)
            e.emit_branch(:b, look)

            e.place_label(looked)
            e.emit(ASM.cmp_imm(5, 0))
            e.emit_branch(:bcond, now, cond: :eq)
            e.emit(ASM.ldr_offset(3, 5, 4))
            e.emit(ASM.lsr_imm(6, 3, 16))
            e.emit(ASM.orr_reg(6, 6, 4)) # the listed switches to clear, and these
            e.emit(ASM.lsl_imm(3, 3, 16))
            e.emit(ASM.lsr_imm(3, 3, 16))
            e.emit(ASM.bic_reg(3, 3, 4)) # the listed ones to set, but these
            e.emit(ASM.lsl_imm(7, ACC, 16))
            e.emit(ASM.orr_reg_lsr(3, 3, 7, 16)) # and these as they are set now
            e.emit(ASM.orr_reg_lsl(3, 3, 6, 16))
            e.emit(ASM.str_offset(3, 5, 4))
            e.emit_branch(:b, done)

            e.place_label(now)
            e.emit(ASM.load_immediate(TMP, REG_SOUNDCNT_L))
            e.emit(ASM.load_halfword(3, TMP))
            e.emit(ASM.bic_reg(3, 3, 4))
            e.emit(ASM.lsl_imm(7, ACC, 16))
            e.emit(ASM.orr_reg_lsr(3, 3, 7, 16))
            e.emit(ASM.store_halfword(3, TMP))
            e.place_label(done)
            e.emit(ASM.pop(2, 3, 4, 5, 6, 7, PC))
          end

          # DROP_VOICE (r0 the distance of a voice's first register, VOICE_REGISTERS of them; r1 its
          # two speaker switches), for the game's own sound on that voice: every listed write of the
          # voice still to come is dropped, and its switches taken out of every listed speaker write,
          # so the game's sound, written at once, is not overtaken by the strike (IR::Tunes, "The
          # game's own sound against a listed strike"). The wave voice's waveforms and wave RAM go
          # with it. A dropped entry becomes a speaker write that changes nothing, so DUE need not
          # look for one. Keeps every register but r0, r1 and r12.
          def emit_drop_voice
            e = @emitter
            look, voice, drop, step, done = Array.new(5) { e.gensym }
            e.place_label(DROP_VOICE)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.orr_reg_lsl(4, TMP, TMP, 16)) # the switches to clear and to set alike
            @primitives.load_var(2, HEAD)
            @primitives.load_var(3, TAIL)
            e.place_label(look)
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, done, cond: :eq)
            e.emit(ASM.load_immediate(7, @list))
            e.emit(ASM.add_reg(7, 7, 2))
            e.emit(ASM.ldr(LR, 7))
            e.emit(ASM.lsl_imm(6, LR, 16))
            e.emit(ASM.lsr_imm(6, 6, 16)) # the register's distance
            e.emit(ASM.cmp_imm(6, SPEAKERS))
            e.emit_branch(:bcond, voice, cond: :ne)
            e.emit(ASM.ldr_offset(5, 7, 4))
            e.emit(ASM.bic_reg(5, 5, 4))
            e.emit(ASM.str_offset(5, 7, 4))
            e.emit_branch(:b, step)

            e.place_label(voice)
            e.emit(ASM.sub_reg(5, 6, ACC))
            e.emit(ASM.cmp_imm(5, VOICE_REGISTERS))
            e.emit_branch(:bcond, drop, cond: :lo)
            e.emit(ASM.cmp_imm(ACC, WAVE_VOICE_AT))
            e.emit_branch(:bcond, step, cond: :ne)
            e.emit(ASM.cmp_imm(6, WAVEFORM))
            e.emit_branch(:bcond, drop, cond: :eq)
            e.emit(ASM.sub_imm(5, 6, WAVE_RAM_AT))
            e.emit(ASM.cmp_imm(5, WAVE_RAM_BYTES))
            e.emit_branch(:bcond, step, cond: :hs)

            e.place_label(drop)
            e.emit(ASM.lsr_imm(LR, LR, 16))
            e.emit(ASM.lsl_imm(LR, LR, 16))
            e.emit(ASM.orr_imm(LR, LR, SPEAKERS))
            e.emit(ASM.str(LR, 7))
            e.emit(ASM.load_immediate(5, 0))
            e.emit(ASM.str_offset(5, 7, 4))
            e.place_label(step)
            e.emit(ASM.add_imm(2, 2, ENTRY_BYTES))
            emit_wrap(2)
            e.emit_branch(:b, look)
            e.place_label(done)
            e.emit(ASM.pop(2, 3, 4, 5, 6, 7, PC))
          end

          # FOLD_PITCH and FOLD_SHAPE (r0 the value, r1 the register's address), for a write at the
          # frame's end. Where the list holds a write of that register, the latest of them takes it
          # in: a pitch keeps the listed write's start bit, so the note is still started with it, and
          # a shape replaces the listed control's low byte. Otherwise the register is written now.
          # Keeps every register but r0, r1 and r12.
          def emit_fold
            e = @emitter
            body, look, other, looked, now, byte, shape_now, done = Array.new(8) { e.gensym }
            e.place_label(FOLD_PITCH)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.load_immediate(6, 0))
            e.emit_branch(:b, body)
            e.place_label(FOLD_SHAPE)
            e.emit(ASM.push(2, 3, 4, 5, 6, 7, LR))
            e.emit(ASM.load_immediate(6, 1))
            e.place_label(body)
            e.emit(ASM.load_immediate(5, 0)) # where the latest of the register is, once found
            e.emit(ASM.lsl_imm(4, TMP, 16))
            e.emit(ASM.lsr_imm(4, 4, 16)) # the register's distance
            @primitives.load_var(2, HEAD)
            @primitives.load_var(3, TAIL)
            e.place_label(look)
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, looked, cond: :eq)
            e.emit(ASM.load_immediate(7, @list))
            e.emit(ASM.add_reg(7, 7, 2))
            e.emit(ASM.ldr(LR, 7))
            e.emit(ASM.lsl_imm(LR, LR, 16))
            e.emit(ASM.cmp_reg_lsr(4, LR, 16))
            e.emit_branch(:bcond, other, cond: :ne)
            e.emit(ASM.mov_reg(5, 7))
            e.place_label(other)
            e.emit(ASM.add_imm(2, 2, ENTRY_BYTES))
            emit_wrap(2)
            e.emit_branch(:b, look)

            e.place_label(looked)
            e.emit(ASM.cmp_imm(5, 0))
            e.emit_branch(:bcond, now, cond: :eq)
            e.emit(ASM.ldr_offset(3, 5, 4))
            e.emit(ASM.cmp_imm(6, 0))
            e.emit_branch(:bcond, byte, cond: :ne)
            e.emit(ASM.and_imm(3, 3, 0x8000))
            e.emit(ASM.orr_reg(3, 3, ACC))
            e.emit(ASM.str_offset(3, 5, 4))
            e.emit_branch(:b, done)
            e.place_label(byte)
            e.emit(ASM.bic_imm(3, 3, 0xFF))
            e.emit(ASM.and_imm(ACC, ACC, 0xFF))
            e.emit(ASM.orr_reg(3, 3, ACC))
            e.emit(ASM.str_offset(3, 5, 4))
            e.emit_branch(:b, done)

            e.place_label(now)
            e.emit(ASM.cmp_imm(6, 0))
            e.emit_branch(:bcond, shape_now, cond: :ne)
            e.emit(ASM.store_halfword(ACC, TMP))
            e.emit_branch(:b, done)
            e.place_label(shape_now)
            e.emit(ASM.strb(ACC, TMP))
            e.place_label(done)
            e.emit(ASM.pop(2, 3, 4, 5, 6, 7, PC))
          end
        end
      end
    end
  end
end
