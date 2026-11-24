# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # Sound effects on a timer, struck inside the frame. A Super Nintendo game's own sound
          # driver runs its effects on the sound unit's timer, not on the console's frames: the
          # SPC700 has three timers of its own (fullsnes, "SNES APU SPC700 I/O Ports", $FA-$FF),
          # and a driver sets timer 0 to its tick and plays each tick's notes the moment it comes,
          # part way through a frame. So does this runtime, for a game whose effects say
          # `on_timer: true` (IR::Tunes.effect_clock_step).
          #
          # ### Who decides, and who strikes
          #
          # The console's processor still plays the effects a frame at a time, ticks counted as every
          # player counts them, so the sound log, who holds which voice and which note plays are the
          # interpreter's. What changes is when the sound unit is told. Each tick's pass over the
          # effects knows where in the frame its tick falls (OFFSET), and the writes that pass
          # sends go in the line ahead of the queue (Sound, "A sound effect goes ahead") between two
          # TIMING commands: FROM, with the tick's offset into the frame, and UNTIL_NOW. The sound unit's
          # program keeps what comes between them in a short list, each with the time it is due,
          # and does each when its time comes. Everything else it does at once, as before.
          #
          # ### The sound unit's clock
          #
          # Timer 0 counts at 8000 a second with its divider at 1, and its 4-bit counter ($FD) is
          # read, and so cleared, each time round the program's wait for the next command, which is
          # far more often than the 2 milliseconds it takes to fill. The program adds it to NOW, a
          # word of the direct page. Each frame of the music starts with MARK: the frame begins at
          # BASE, which is NOW, or a frame after the last BASE if that is later, so frames the console
          # caught up on in one go are struck a frame apart rather than on top of each other. A frame
          # of the sound unit's clock is one unit short of a real one (#units_a_frame), so BASE never
          # runs ahead of the frames the console shows. A note FROM names is due LEAD_COUNTS after
          # BASE and its offset, which is held below that frame.
          #
          # ### In the order they were played
          #
          # MARK goes in the line ahead like the rest, so the sound unit is told each frame's MARK,
          # then its FROMs, notes and UNTIL_NOWs, in the order the frames were played: a pass that
          # took two frames sends the first frame's MARK and notes, then the second's, and a MARK
          # never comes between a FROM and its UNTIL_NOW. A frame starts when its MARK comes, so a
          # game too busy to send them on time has its notes struck their ticks apart from when they
          # are sent, as late as all else it shows. The frame waits for the line to be sent
          # (Sound#emit_ahead_sent_at_frame), so a game that has the time sends each MARK as its
          # frame's music has been played, and LEAD_COUNTS covers the commands that come after it
          # before a tick at the frame's start is due. Only when the line is full does MARK go at
          # once, ahead of what is waiting.
          #
          # ### What it costs
          #
          # Nothing for a game without the word, whose program and runtime are as before. With it,
          # the sound unit's program grows by its clock and its list, and a frame sends MARK (one turn of
          # the mailboxes) and two more commands for each tick that strikes something, waiting for them.
          # The list holds LIST_ENTRIES commands; one more that comes while it is full is done at
          # once, and a frame holds IR::Tunes::MOST_TICKS_A_FRAME ticks at most.
          module Strikes
            # The command that tells the sound unit when (Sound's commands; the fifteenth, which no
            # other uses), and what its second number says: a frame begins, the commands after this
            # are due at the offset its first number gives, they are done at once again, or the game's
            # own sound is on the voice whose registers start at its first number (DROP).
            TIMING = 15
            MARK = 0
            FROM = 1
            UNTIL_NOW = 2
            DROP = 3

            # The sound unit's timer: 8000 counts a second from timer 0 with its divider at 1, and the
            # control register's bits that switch timer 0 on and keep the built-in program readable.
            TIMER_RATE = 8000
            TIMER_0_TARGET = 0xFA
            TIMER_CONTROL = 0xF1
            TIMER_0_COUNTER = 0xFD
            TIMER_0_ON = 0x81

            # The sound unit's program's direct page, past Sound's own: the command being done (its
            # three numbers, as Sound's commands read them from the mailboxes), whether commands are
            # kept for later, NOW, BASE, when the commands coming are due, a word to work in, the
            # list's count and its two ends, and the list's own NEXT_PITCH to NEXT_GAIN (LIST_NEXT).
            COMMAND = 0x0C
            COMMAND_COPY = [nil, COMMAND, 0x0D, 0x0E].freeze
            LIST_INCOMING = 0x0F
            NOW = 0x10
            BASE = 0x12
            DUE = 0x14
            WORK = 0x16
            LISTED = 0x18
            LIST_HEAD = 0x19
            LIST_TAIL = 0x1A
            LIST_NEXT = 0x1B
            NEXT_BYTES = 6
            # The list, a ring of LIST_ENTRIES: each entry's command, its two numbers, and when it is
            # due, low and high, each in a table of its own, one byte an entry.
            LIST_ENTRIES = 32
            LIST_COMMANDS = 0x40
            LIST_FIRSTS = 0x60
            LIST_SECONDS = 0x80
            LIST_DUE_LOW = 0xA0
            LIST_DUE_HIGH = 0xC0
            # How far behind its MARK a frame's notes are struck, in counts of the timer: four
            # milliseconds, time for a tick's few commands to be sent after the MARK.
            LEAD_COUNTS = 32
            # How many looks at the mailbox a frame spends sending the line ahead before it gives up
            # (Sound#emit_ahead_sent_at_frame): room for the whole line, each command given as many
            # looks as a write is given for its answer (Sound::PATIENCE).
            SENT_TRIES = Sound::AHEAD_ENTRIES * Sound::PATIENCE

            # The console's side: whether FROM was sent for the pass playing now and UNTIL_NOW is owed, and
            # where the tick playing now falls in the frame, in 256ths of the sound unit's counts.
            FROM_SENT = "rt strikes from sent"
            OFFSET = "rt strikes offset"

            module_function

            def reserve(memory)
              memory.reserve(FROM_SENT, 2)
              memory.reserve(OFFSET, 2)
            end

            # How many counts of the sound unit's timer a frame of the console lasts, exactly.
            def counts_a_frame = TIMER_RATE * Console::SUPER_NINTENDO.frame_seconds

            # ...and the frame the sound unit's clock keeps (BASE's step): a count short, rounded down.
            def units_a_frame = counts_a_frame.floor - 1

            # How many counts a tick of the effects' timer lasts, which a frame adding +step+ has
            # (IR::Tunes.effect_clock_step): in 256ths, for each later tick of a frame, and whole, for
            # the multiplier that finds the first.
            def tick_in_256ths(step) = (counts_a_frame * IR::Tunes::CLOCK_MODULUS * 256 / step).round
            def tick_counts(step) = (counts_a_frame * IR::Tunes::CLOCK_MODULUS / step).round

            # --- the sound unit's program (Sound.driver) ---

            # Timer 0 started, as the program starts.
            def emit_timer_start(spc)
              spc.instance_eval do
                mov direct(TIMER_0_TARGET), imm(1)
                mov direct(TIMER_CONTROL), imm(TIMER_0_ON)
                mov :a, direct(TIMER_0_COUNTER) # read, and so cleared
              end
            end

            # strikes_clock (CALL): NOW moved on by the timer's count, and every command of the list
            # whose time has come done, oldest first, through dispatch (Sound.driver). strikes_mailbox
            # (CALL): the command the mailboxes hold, copied into COMMAND_COPY, done, kept for later, or
            # a TIMING command. strikes_timing and strikes_store, reached from it. strikes_swap_next
            # (CALL), below.
            def emit_routines(spc)
              emit_clock(spc)
              emit_mailbox_command(spc)
              emit_timing(spc)
              emit_store(spc)
              emit_drop(spc)
              emit_swap_next(spc)
            end

            # strikes_swap_next: NEXT_PITCH to NEXT_GAIN, the note the sound unit is being told, changed
            # over with LIST_NEXT. A note's pitch and envelope are commands of their own, ahead of the
            # note (Sound#emit_whole_note_commands), and the list's commands and those done at once
            # are two lines of them, each held while the other's are done: a pitch done from the list
            # with its note still to come waits in LIST_NEXT, and one done at once is not overwritten
            # by the list's. Both are kept by changing them over before the list's commands and after.
            def emit_swap_next(spc)
              spc.label("strikes_swap_next")
              NEXT_BYTES.times do |n|
                spc.mov(:a, spc.direct(Sound::NEXT_PITCH + n))
                spc.mov(:y, spc.direct(LIST_NEXT + n))
                spc.mov(spc.direct(LIST_NEXT + n), :a)
                spc.mov(spc.direct(Sound::NEXT_PITCH + n), :y)
              end
              spc.ret
            end

            def emit_clock(spc)
              due_check = lambda do |past|
                spc.instance_eval do
                  mov :x, direct(LIST_HEAD)
                  mov :a, direct(NOW)
                  setc
                  sbc :a, direct_x(LIST_DUE_LOW)
                  mov :a, direct(NOW + 1)
                  sbc :a, direct_x(LIST_DUE_HIGH)
                  bmi past # not yet
                end
              end
              spc.instance_eval do
                label "strikes_clock"
                mov :a, direct(TIMER_0_COUNTER)
                beq "strikes_clock_counted"
                clrc
                adc :a, direct(NOW)
                mov direct(NOW), :a
                mov :a, direct(NOW + 1)
                adc :a, imm(0)
                mov direct(NOW + 1), :a
                label "strikes_clock_counted"
                mov :a, direct(LISTED)
                beq "strikes_clock_done"
              end
              due_check.call("strikes_clock_done")
              spc.call("strikes_swap_next")
              spc.instance_eval do
                label "strikes_clock_due"
                mov :x, direct(LIST_HEAD)
                mov :a, direct_x(LIST_COMMANDS)
                mov direct(COMMAND_COPY[1]), :a
                mov :a, direct_x(LIST_FIRSTS)
                mov direct(COMMAND_COPY[2]), :a
                mov :a, direct_x(LIST_SECONDS)
                mov direct(COMMAND_COPY[3]), :a
                mov :a, :x
                inc :a
                and_ :a, imm(LIST_ENTRIES - 1)
                mov direct(LIST_HEAD), :a
                dec direct(LISTED)
                mov :a, direct(COMMAND_COPY[1])
                call "dispatch"
                mov :a, direct(LISTED)
                beq "strikes_clock_struck"
              end
              due_check.call("strikes_clock_struck")
              spc.bra("strikes_clock_due")
              spc.label("strikes_clock_struck")
              spc.call("strikes_swap_next")
              spc.label("strikes_clock_done")
              spc.ret
            end

            def emit_mailbox_command(spc)
              spc.instance_eval do
                label "strikes_mailbox"
                mov direct(COMMAND_COPY[1]), direct(Sound::PORTS[1])
                mov direct(COMMAND_COPY[2]), direct(Sound::PORTS[2])
                mov direct(COMMAND_COPY[3]), direct(Sound::PORTS[3])
                mov :a, direct(COMMAND_COPY[1])
                cmp :a, imm(TIMING)
                bne "strikes_mailbox_not_timing"
                jmp "strikes_timing"
                label "strikes_mailbox_not_timing"
                mov :x, direct(LIST_INCOMING)
                beq "strikes_mailbox_at_once"
                and_ :a, imm(Sound::COMMAND_BITS)
                cmp :a, imm(Sound::LOAD_AT) # a scene's recordings are never kept
                bcs "strikes_mailbox_at_once"
                jmp "strikes_store"
                label "strikes_mailbox_at_once"
                mov :a, direct(COMMAND_COPY[1])
                jmp "dispatch"
              end
            end

            # strikes_timing: MARK, FROM or UNTIL_NOW (COMMAND_COPY's second number), its first number FROM's
            # offset in counts. Only UNTIL_NOW ends the list's taking commands, which FROM starts.
            def emit_timing(spc)
              frame = units_a_frame
              spc.instance_eval do
                label "strikes_timing"
                mov :a, direct(COMMAND_COPY[3])
                cmp :a, imm(MARK)
                bne "strikes_timing_from"
                mov :a, direct(BASE) # a frame after the last BASE...
                clrc
                adc :a, imm(frame & 0xFF)
                mov direct(WORK), :a
                mov :a, direct(BASE + 1)
                adc :a, imm(frame >> 8)
                mov direct(WORK + 1), :a
                mov :a, direct(NOW) # ...or NOW, whichever is later
                setc
                sbc :a, direct(WORK)
                mov :a, direct(NOW + 1)
                sbc :a, direct(WORK + 1)
                bmi "strikes_timing_later"
                movw :ya, direct(NOW)
                movw direct(BASE), :ya
                ret
                label "strikes_timing_later"
                movw :ya, direct(WORK)
                movw direct(BASE), :ya
                ret
                label "strikes_timing_from"
                cmp :a, imm(DROP)
                bne "strikes_timing_not_drop"
                jmp "strikes_drop"
                label "strikes_timing_not_drop"
                cmp :a, imm(FROM)
                bne "strikes_timing_until_now"
                mov :a, direct(COMMAND_COPY[2])
                clrc
                adc :a, imm(LEAD_COUNTS) # held below a frame, so no carry
                adc :a, direct(BASE)
                mov direct(DUE), :a
                mov :a, direct(BASE + 1)
                adc :a, imm(0)
                mov direct(DUE + 1), :a
                mov direct(LIST_INCOMING), imm(1)
                ret
                label "strikes_timing_until_now"
                mov direct(LIST_INCOMING), imm(0)
                ret
              end
            end

            # strikes_store: the command COMMAND_COPY holds put on the list, due at DUE; done at once when the
            # list is full.
            def emit_store(spc)
              spc.instance_eval do
                label "strikes_store"
                mov :a, direct(LISTED)
                cmp :a, imm(LIST_ENTRIES)
                bcc "strikes_store_room"
                call "strikes_swap_next" # done at once, as one of the list's
                mov :a, direct(COMMAND_COPY[1])
                call "dispatch"
                jmp "strikes_swap_next"
                label "strikes_store_room"
                mov :x, direct(LIST_TAIL)
                mov :a, direct(COMMAND_COPY[1])
                mov direct_x(LIST_COMMANDS), :a
                mov :a, direct(COMMAND_COPY[2])
                mov direct_x(LIST_FIRSTS), :a
                mov :a, direct(COMMAND_COPY[3])
                mov direct_x(LIST_SECONDS), :a
                mov :a, direct(DUE)
                mov direct_x(LIST_DUE_LOW), :a
                mov :a, direct(DUE + 1)
                mov direct_x(LIST_DUE_HIGH), :a
                mov :a, :x
                inc :a
                and_ :a, imm(LIST_ENTRIES - 1)
                mov direct(LIST_TAIL), :a
                inc direct(LISTED)
                ret
              end
            end

            # strikes_drop: the game's own sound is on the voice whose registers start at COMMAND_COPY's
            # first number (IR::Tunes, "The game's own sound against a listed strike"). The console
            # writes it as the game plays it, after the frame's ticks have been listed, so every listed
            # write still waiting for that voice is dropped here, before it can strike over the game's
            # sound: a note told whole on the voice, a write to one of the voice's own registers, and a
            # write to the noise switches when the voice is the noise voice; the voice's bit is taken out
            # of a waiting key-on and key-off, and the noise clock's bits out of a waiting flags write for
            # the noise voice. A dropped entry becomes a key-off of no voice, which leaves KOFF as it is.
            def emit_drop(spc)
              dsp = DSPWrites
              noise_base = dsp::NOISE_VOICE << 4
              spc.instance_eval do
                label "strikes_drop"
                mov :a, direct(COMMAND_COPY[2])
                4.times { lsr :a }
                mov :x, :a
                mov :a, abs_x("voice_bits")
                eor :a, imm(0xFF)
                mov direct(WORK), :a # every voice's bit but this one
                mov :y, direct(LISTED)
                beq "strikes_drop_done"
                mov :x, direct(LIST_HEAD)
                label "strikes_drop_entry"
                mov :a, direct_x(LIST_COMMANDS)
                cmp :a, imm(Sound::SET_KEY_OFF_BITS)
                bne "strikes_drop_not_key_off"
                mov :a, direct_x(LIST_FIRSTS)
                and_ :a, direct(WORK)
                mov direct_x(LIST_FIRSTS), :a
                bra "strikes_drop_next"
                label "strikes_drop_not_key_off"
                cmp :a, imm(Sound::SET_FLAG_BITS)
                bne "strikes_drop_not_flags"
                mov :a, direct(COMMAND_COPY[2])
                cmp :a, imm(noise_base)
                bne "strikes_drop_next"
                mov :a, direct_x(LIST_FIRSTS)
                and_ :a, imm(~dsp::NOISE_CLOCK & 0xFF)
                mov direct_x(LIST_FIRSTS), :a
                bra "strikes_drop_next"
                label "strikes_drop_not_flags"
                cmp :a, imm(Sound::WRITE_DSP)
                beq "strikes_drop_write"
                and_ :a, imm(Sound::COMMAND_BITS) # a note told whole names its voice in its command
                cmp :a, imm(Sound::WHOLE_NOTE)
                bne "strikes_drop_next"
                mov :a, direct_x(LIST_COMMANDS)
                and_ :a, imm(Sound::VOICE_BITS)
                cmp :a, direct(COMMAND_COPY[2])
                bne "strikes_drop_next"
                bra "strikes_drop_dropped"
                label "strikes_drop_write"
                mov :a, direct_x(LIST_FIRSTS)
                cmp :a, imm(dsp::KEY_ON)
                bne "strikes_drop_not_key_on"
                mov :a, direct_x(LIST_SECONDS)
                and_ :a, direct(WORK)
                mov direct_x(LIST_SECONDS), :a
                bra "strikes_drop_next"
                label "strikes_drop_not_key_on"
                cmp :a, imm(dsp::NOISE_ON)
                bne "strikes_drop_not_noise_on"
                mov :a, direct(COMMAND_COPY[2])
                cmp :a, imm(noise_base)
                bne "strikes_drop_next"
                bra "strikes_drop_dropped"
                label "strikes_drop_not_noise_on"
                and_ :a, imm(0x08) # $x8 to $xF are the registers every voice shares
                bne "strikes_drop_next"
                mov :a, direct_x(LIST_FIRSTS)
                and_ :a, imm(0xF0)
                cmp :a, direct(COMMAND_COPY[2])
                bne "strikes_drop_next"
                label "strikes_drop_dropped"
                mov :a, imm(Sound::SET_KEY_OFF_BITS)
                mov direct_x(LIST_COMMANDS), :a
                mov :a, imm(0)
                mov direct_x(LIST_FIRSTS), :a
                label "strikes_drop_next"
                mov :a, :x
                inc :a
                and_ :a, imm(LIST_ENTRIES - 1)
                mov :x, :a
                dbnz :y, "strikes_drop_entry"
                label "strikes_drop_done"
                ret
              end
            end

            # --- for a reader of a running cartridge ---

            # The DSP's registers (+dsp+, its 128 bytes) as the sound unit will leave them once it has done
            # every command its list holds, read from its memory (+ram+): for a checked run, which holds the
            # registers to the interpreter's log at every pass, those whose notes are still listed among
            # them. Each command does here what the program does with it (Sound.driver,
            # Sound#emit_whole_note_commands, a note told whole from the list's own NEXT bytes, LIST_NEXT),
            # so a change to what the program does with a command is a change here too. +chip_envelopes+
            # and +sides+ are the build's, as Sound.driver is given them.
            def registers_after_list(dsp, ram, chip_envelopes:, sides:)
              registers = dsp.bytes
              next_bytes = ram.byteslice(LIST_NEXT, NEXT_BYTES).bytes
              at = ram.getbyte(LIST_HEAD)
              ram.getbyte(LISTED).times do
                command, first, second = [LIST_COMMANDS, LIST_FIRSTS, LIST_SECONDS].map { |table| ram.getbyte(table + at) }
                apply_listed_command(registers, next_bytes, command, first, second, chip_envelopes: chip_envelopes, sides: sides)
                at = (at + 1) & (LIST_ENTRIES - 1)
              end
              registers.pack("C*")
            end

            # One command of the list done on +registers+ (an Array of the DSP's bytes), the note's bytes in
            # +next_bytes+ (NEXT_PITCH to NEXT_GAIN, from NEXT_PITCH on).
            def apply_listed_command(registers, next_bytes, command, first, second, chip_envelopes:, sides:)
              dsp = DSPWrites
              set_bits = ->(register) { registers[register] = (registers[register] & ~first & 0xFF) | (second & first) }
              base = command & Sound::VOICE_BITS
              case command & Sound::COMMAND_BITS
              when Sound::WRITE_DSP then registers[first] = second
              when Sound::SET_FLAG_BITS then set_bits.call(dsp::FLAGS)
              when Sound::SET_KEY_OFF_BITS then set_bits.call(dsp::KEY_OFF)
              when Sound::HOLD_PITCH then next_bytes[0, 2] = [first, second]
              when Sound::HOLD_ENVELOPE then next_bytes[2, 2] = [first, second]
              when Sound::HOLD_GAIN then next_bytes[4] = first
              when Sound::VOICE_LOUDNESS
                registers[base + dsp::VOLUME_LEFT] = sides ? first : second
                registers[base + dsp::VOLUME_RIGHT] = second
              when Sound::WHOLE_NOTE
                registers[base + dsp::VOLUME_LEFT] = registers[base + dsp::VOLUME_RIGHT] = second unless sides
                registers[base + dsp::PITCH_LOW], registers[base + dsp::PITCH_HIGH] = next_bytes[0, 2]
                registers[base + dsp::SOURCE] = first
                if chip_envelopes
                  registers[base + dsp::ADSR1], registers[base + dsp::ADSR2], registers[base + dsp::GAIN] = next_bytes[2, 3]
                else
                  registers[base + dsp::ADSR1] = dsp::ADSR_OFF
                  registers[base + dsp::GAIN] = dsp::FIXED_TOP
                end
                bit = 1 << (base >> 4)
                registers[dsp::KEY_OFF] &= ~bit & 0xFF
                registers[dsp::KEY_ON] = bit
              end
            end

            # --- the console's side ---

            # rt_strikes_mark (JSL): MARK put in the line ahead as a frame of the music begins, or sent at
            # once when the line is full.
            # rt_strikes_push (JSL): the command R2 with R0 and R1 put in the line ahead, the carry set
            # when it went in. A full line is sent from until there is room, up to SENT_TRIES looks at
            # the mailbox, and the carry is clear when none was made: every command of a tick goes the
            # one way, so the sound unit takes a note's pitch and the note itself the same way.
            # rt_strikes_drop (JSL): DROP for the voice whose first register R0 names, sent as the
            # game's own sound is, in the queue behind the frame's listed notes. rt_strikes_close
            # (JSL): UNTIL_NOW sent after a pass that sent FROM.
            def emit(asm, memory)
              asm.label("rt_strikes_mark")
              asm.lda(TIMING)
              asm.sta(asm.direct(Sound::R2))
              asm.stz(asm.direct(Sound::R0))
              asm.lda(MARK)
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_strikes_push"))
              asm.bcs("rt_strikes_mark_done")
              asm.jml(asm.long("rt_sound_command_at_once"))
              asm.label("rt_strikes_mark_done")
              asm.rtl
              emit_push(asm, memory)
              asm.label("rt_strikes_drop") # R0 the voice's first register
              asm.lda(DROP)
              asm.sta(asm.direct(Sound::R1))
              asm.lda(TIMING)
              asm.jml(asm.long("rt_sound_command"))
              asm.label("rt_strikes_close")
              asm.lda(asm.abs(memory[FROM_SENT]))
              asm.beq("rt_strikes_close_done")
              asm.stz(asm.abs(memory[FROM_SENT]))
              asm.lda(TIMING)
              asm.sta(asm.direct(Sound::R2))
              asm.stz(asm.direct(Sound::R0))
              asm.lda(UNTIL_NOW)
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_strikes_push"))
              asm.label("rt_strikes_close_done")
              asm.rtl
            end

            def emit_push(asm, memory)
              s = Sound
              asm.label("rt_strikes_push")
              asm.phy
              asm.ldy(SENT_TRIES)
              asm.label("rt_strikes_push_try")
              asm.ldx(asm.abs(memory[s::AHEAD_TAIL]))
              asm.txa
              asm.clc
              asm.adc(s::ENTRY_BYTES)
              asm.and_a(s::AHEAD_MASK)
              asm.cmp(asm.abs(memory[s::AHEAD_HEAD]))
              asm.beq("rt_strikes_push_full")
              asm.sta(asm.abs(memory[s::AHEAD_TAIL]))
              asm.lda(asm.direct(s::R2))
              asm.sta(memory.indexed(asm, s::AHEAD, s::ENTRY_COMMAND))
              asm.lda(asm.direct(s::R0))
              asm.sta(memory.indexed(asm, s::AHEAD, s::ENTRY_REGISTER))
              asm.lda(asm.direct(s::R1))
              asm.sta(memory.indexed(asm, s::AHEAD, s::ENTRY_VALUE))
              asm.ply
              asm.sec
              asm.rtl
              asm.label("rt_strikes_push_full") # room made by sending the oldest, as the queue makes it
              [s::R0, s::R1, s::R2].each do |register|
                asm.lda(asm.direct(register))
                asm.pha
              end
              asm.jsl(asm.long("rt_sound_send_queued"))
              [s::R2, s::R1, s::R0].each do |register|
                asm.pla
                asm.sta(asm.direct(register))
              end
              asm.dey
              asm.bne("rt_strikes_push_try")
              asm.ply
              asm.clc
              asm.rtl
            end

            # What rt_sound_command does with a write while an effect plays, in a game whose effects are
            # struck inside the frame (Sound#emit_write_ahead): FROM put in the line ahead first, once a
            # pass, with the tick's offset in whole counts, held below a frame; then the write, or into
            # the queue as any other when the line is full.
            def emit_write_ahead(asm, memory)
              s = Sound
              asm.lda(asm.abs(memory[s::ASKING_AHEAD]))
              asm.beq("rt_sound_write_in_line")
              asm.lda(asm.abs(memory[FROM_SENT]))
              asm.bne("rt_strikes_write_opened")
              [s::R0, s::R1, s::R2].each do |register|
                asm.lda(asm.direct(register))
                asm.pha
              end
              asm.lda(TIMING)
              asm.sta(asm.direct(s::R2))
              asm.lda(FROM)
              asm.sta(asm.direct(s::R1))
              asm.lda(asm.abs(memory[OFFSET]))
              asm.xba
              asm.and_a(0xFF)
              asm.cmp(units_a_frame)
              asm.bcc("rt_strikes_write_offset_held")
              asm.lda(units_a_frame - 1)
              asm.label("rt_strikes_write_offset_held")
              asm.sta(asm.direct(s::R0))
              asm.jsl(asm.long("rt_strikes_push"))
              asm.bcc("rt_strikes_write_unopened")
              asm.lda(1)
              asm.sta(asm.abs(memory[FROM_SENT]))
              asm.label("rt_strikes_write_unopened")
              [s::R2, s::R1, s::R0].each do |register|
                asm.pla
                asm.sta(asm.direct(register))
              end
              asm.label("rt_strikes_write_opened")
              asm.jsl(asm.long("rt_strikes_push"))
              asm.branch_long(:bcs, "rt_sound_write_done")
              asm.label("rt_sound_write_in_line")
            end

            # Where the first tick of a frame falls (OFFSET), before the effects' timer moves on: the
            # count's 65536ths still to go before it comes round, a 256th at a time, times a tick's
            # counts — so in 256ths of a count. A count of nought has the whole of 65536 to go, held
            # at 255 256ths. Two runs of the 8-bit multiplier where a tick lasts 256 counts or more.
            def emit_first_offset(asm, memory, clock, step)
              h = Console::SNESHardware
              counts = tick_counts(step)
              asm.lda(asm.abs(memory[clock]))
              asm.eor(0xFFFF)
              asm.inc
              asm.xba
              asm.and_a(0xFF)
              asm.bne("rt_strikes_first_some")
              asm.lda(0xFF)
              asm.label("rt_strikes_first_some")
              asm.sep(0x20)
              asm.sta(asm.abs(h::WRMPYA))
              asm.lda(counts & 0xFF)
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop } # the product is ready eight cycles on
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.sta(asm.abs(memory[OFFSET]))
              return if counts < 256

              asm.sep(0x20)
              asm.lda(counts >> 8)
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop }
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.xba
              asm.and_a(0xFF00)
              asm.clc
              asm.adc(asm.abs(memory[OFFSET]))
              asm.sta(asm.abs(memory[OFFSET]))
            end

            # ...and each later tick, a tick on.
            def emit_next_offset(asm, memory, step)
              asm.lda(asm.abs(memory[OFFSET]))
              asm.clc
              asm.adc(tick_in_256ths(step))
              asm.sta(asm.abs(memory[OFFSET]))
            end
          end
        end
      end
    end
  end
end
