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
          # effects knows where in the frame its tick falls (STRIKE_OFFSET), and the writes that pass
          # sends go in the line ahead of the queue (Sound, "A sound effect goes ahead") between two
          # TIMING commands: FROM, with the tick's offset into the frame, and END. The sound unit's
          # program keeps what comes between them in a short list, each with the time it is due,
          # and does each when its time comes. Everything else it does at once, as before.
          #
          # ### The sound unit's clock
          #
          # Timer 0 counts at 8000 a second with its divider at 1, and its 4-bit counter ($FD) is
          # read, and so cleared, each time round the program's wait for the next command, which is
          # far more often than the 2 milliseconds it takes to fill. The program adds it to NOW, a
          # word of the direct page. Each frame of the music starts with MARK, sent at once rather
          # than queued: the frame begins at BASE, which is NOW, or a frame after the last BASE if
          # that is later, so frames the console caught up on in one go are struck a frame apart
          # rather than on top of each other. A frame of the sound unit's clock is one unit short
          # of a real one (#units_a_frame), so BASE never runs ahead of the frames the console
          # shows. A note FROM names is due at BASE plus its offset, which is held below that frame.
          #
          # ### What it costs
          #
          # Nothing for a game without the word, whose program and runtime are as before. With it,
          # the sound unit's program grows by its clock and its list, and a frame sends MARK at once
          # (one turn of the mailboxes) and two more commands for each tick that strikes something.
          # The list holds LIST_ENTRIES commands; one more that comes while it is full is done at
          # once, and a frame holds IR::Tunes::MOST_TICKS_A_FRAME ticks at most.
          module Strikes
            # The command that tells the sound unit when (Sound's commands; the fifteenth, which no
            # other uses), and what its second number says: a frame begins, the commands after this
            # are due at the offset its first number gives, or they are done at once again.
            TIMING = 15
            MARK = 0
            FROM = 1
            UNTIL_NOW = 2

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
            # list's count and its two ends, and NEXT_PITCH to NEXT_GAIN kept while the list is done.
            COMMAND = 0x0C
            TOLD = [nil, COMMAND, 0x0D, 0x0E].freeze
            KEEPING = 0x0F
            NOW = 0x10
            BASE = 0x12
            DUE = 0x14
            WORK = 0x16
            LISTED = 0x18
            LIST_HEAD = 0x19
            LIST_TAIL = 0x1A
            KEPT_NEXT = 0x1B
            NEXT_BYTES = 6
            # The list, a ring of LIST_ENTRIES: each entry's command, its two numbers, and when it is
            # due, low and high, each in a table of its own, one byte an entry.
            LIST_ENTRIES = 32
            LIST_COMMANDS = 0x40
            LIST_FIRSTS = 0x60
            LIST_SECONDS = 0x80
            LIST_DUE_LOW = 0xA0
            LIST_DUE_HIGH = 0xC0

            # The console's side: whether FROM was sent for the pass playing now and END is owed, and
            # where the tick playing now falls in the frame, in 256ths of the sound unit's counts.
            OPEN = "rt strikes open"
            OFFSET = "rt strikes offset"

            module_function

            def reserve(memory)
              memory.reserve(OPEN, 2)
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
            # whose time has come done, oldest first, through dispatch (Sound.driver), with the note
            # being told kept as it was round them. strikes_take (CALL): the command the mailboxes
            # hold, copied into TOLD, done, kept for later, or a TIMING command. strikes_timing and
            # strikes_store, reached from it.
            def emit_routines(spc)
              emit_clock(spc)
              emit_take(spc)
              emit_timing(spc)
              emit_store(spc)
            end

            def emit_clock(spc)
              kept = (0...NEXT_BYTES).map { |n| [Sound::NEXT_PITCH + n, KEPT_NEXT + n] }
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
              kept.each { |from, to| spc.mov(spc.direct(to), spc.direct(from)) }
              spc.instance_eval do
                label "strikes_clock_due"
                mov :x, direct(LIST_HEAD)
                mov :a, direct_x(LIST_COMMANDS)
                mov direct(TOLD[1]), :a
                mov :a, direct_x(LIST_FIRSTS)
                mov direct(TOLD[2]), :a
                mov :a, direct_x(LIST_SECONDS)
                mov direct(TOLD[3]), :a
                mov :a, :x
                inc :a
                and_ :a, imm(LIST_ENTRIES - 1)
                mov direct(LIST_HEAD), :a
                dec direct(LISTED)
                mov :a, direct(TOLD[1])
                call "dispatch"
                mov :a, direct(LISTED)
                beq "strikes_clock_struck"
              end
              due_check.call("strikes_clock_struck")
              spc.bra("strikes_clock_due")
              spc.label("strikes_clock_struck")
              kept.each { |from, to| spc.mov(spc.direct(from), spc.direct(to)) }
              spc.label("strikes_clock_done")
              spc.ret
            end

            def emit_take(spc)
              spc.instance_eval do
                label "strikes_take"
                mov direct(TOLD[1]), direct(Sound::PORTS[1])
                mov direct(TOLD[2]), direct(Sound::PORTS[2])
                mov direct(TOLD[3]), direct(Sound::PORTS[3])
                mov :a, direct(TOLD[1])
                cmp :a, imm(TIMING)
                bne "strikes_take_command"
                jmp "strikes_timing"
                label "strikes_take_command"
                mov :x, direct(KEEPING)
                beq "strikes_take_now"
                and_ :a, imm(Sound::COMMAND_BITS)
                cmp :a, imm(Sound::LOAD_AT) # a scene's recordings are never kept
                bcs "strikes_take_now"
                jmp "strikes_store"
                label "strikes_take_now"
                mov :a, direct(TOLD[1])
                jmp "dispatch"
              end
            end

            # strikes_timing: MARK, FROM or UNTIL_NOW (TOLD's second number), its first number FROM's
            # offset in counts.
            def emit_timing(spc)
              frame = units_a_frame
              spc.instance_eval do
                label "strikes_timing"
                mov direct(KEEPING), imm(0)
                mov :a, direct(TOLD[3])
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
                cmp :a, imm(FROM)
                bne "strikes_timing_done"
                mov :a, direct(TOLD[2])
                clrc
                adc :a, direct(BASE)
                mov direct(DUE), :a
                mov :a, direct(BASE + 1)
                adc :a, imm(0)
                mov direct(DUE + 1), :a
                mov direct(KEEPING), imm(1)
                label "strikes_timing_done"
                ret
              end
            end

            # strikes_store: the command TOLD holds put on the list, due at DUE; done at once when the
            # list is full.
            def emit_store(spc)
              spc.instance_eval do
                label "strikes_store"
                mov :a, direct(LISTED)
                cmp :a, imm(LIST_ENTRIES)
                bcc "strikes_store_room"
                mov :a, direct(TOLD[1])
                jmp "dispatch"
                label "strikes_store_room"
                mov :x, direct(LIST_TAIL)
                mov :a, direct(TOLD[1])
                mov direct_x(LIST_COMMANDS), :a
                mov :a, direct(TOLD[2])
                mov direct_x(LIST_FIRSTS), :a
                mov :a, direct(TOLD[3])
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

            # --- the console's side ---

            # rt_strikes_mark (JSL): MARK sent at once, as a frame of the music begins.
            # rt_strikes_push (JSL): the command R2 with R0 and R1 put in the line ahead, the carry set
            # when it went in and clear when the line is full. rt_strikes_close (JSL): END sent after a
            # pass that sent FROM.
            def emit(asm, memory)
              asm.label("rt_strikes_mark")
              asm.lda(TIMING)
              asm.sta(asm.direct(Sound::R2))
              asm.stz(asm.direct(Sound::R0))
              asm.lda(MARK)
              asm.sta(asm.direct(Sound::R1))
              asm.jml(asm.long("rt_sound_command_at_once"))
              emit_push(asm, memory)
              asm.label("rt_strikes_close")
              asm.lda(asm.abs(memory[OPEN]))
              asm.beq("rt_strikes_close_done")
              asm.stz(asm.abs(memory[OPEN]))
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
              asm.sec
              asm.rtl
              asm.label("rt_strikes_push_full")
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
              asm.lda(asm.abs(memory[OPEN]))
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
              asm.sta(asm.abs(memory[OPEN]))
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
