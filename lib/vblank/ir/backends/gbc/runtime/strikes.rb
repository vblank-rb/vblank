# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # Sound effects on a timer, struck inside the frame. A cartridge's sound driver that counts
          # its effects' ticks on a timer writes each note to the sound chip as its tick comes, part
          # way through a frame, where the player here writes every note as it plays the frame. For a
          # game whose effects say `on_timer: true` (IR::Tunes.effect_clock_step) it does the same as
          # such a driver.
          #
          # ### Who decides, and when the chip is told
          #
          # The music player still plays the effects a frame at a time, ticks counted as every player
          # counts them, so the sound log, who holds which voice and which note plays are the
          # interpreter's. While a tick's pass over the effects plays (STRIKING), each write it makes to
          # the sound chip (rt_sound_put: a voice's registers, the wave voice's waveform) is put on a list
          # with the line it is due on (DUE): the frame's first line (BASE) and the part of the frame the
          # tick comes after. Lines are counted from power-on (BLANK_LINES, moved on a frame at each
          # blank, and rt_line_now), so a frame's lines and the next frame's never meet. A line is 456
          # of the display's dots, some 109 microseconds (Pan Docs, "Rendering"), so a note lands within
          # a line of its tick.
          #
          # The player plays a frame's music after the blank, when the game waits, and a pass that took
          # several frames plays all of theirs one after the other then. So a frame starts at the
          # blank the music is played after, or a frame after the one played before it, whichever is
          # later: the frames of a slow pass are struck a frame apart from when they are played, as
          # late as everything else such a game shows, and not all at once.
          #
          # ### The alarm
          #
          # The list's first entry sets the timer going (rt_strikes_due): counting at the processor's
          # clock over 1024, 8192 times a second at the double speed the game runs at, from 256 less
          # the counts to go, so its interrupt comes as the line does (Pan Docs, "Timer and Divider
          # Registers"). The interrupt writes every entry whose line has come and sets the timer going
          # for the next, or stops it. A wait longer than the timer holds sets it for as long as it
          # holds, and the interrupt sets it again.
          #
          # In a game that plays a recording the timer is the recording's (Runtime::Clips), and the
          # alarm is the display's line match instead (#emit_set_line): LYC set to the line the entry
          # is due on, and the display's interrupt raised as it starts that line, which the line
          # interrupt shares with a bent background's rows (Runtime::Picture, rt_hblank_interrupt): it
          # answers the strikes first, and bends a row only at a line's end. The display's interrupt
          # then stays on, and a background with no bend switches off the line's end rather than the
          # interrupt. A game whose status bar covers the sprites wants the line match for the bar's top
          # too, so the two share it (#emit_line_match_set): it is set for whichever comes first, and the
          # interrupt answers the strikes and then the bar.
          #
          # ### Writes outside the pass
          #
          # The song's writes, and those the frame's end makes for a wobbling or a stepping note, are
          # done at once, unless the list holds a write of the same register: then the latest of
          # those takes the new value, keeping its start bit on a voice's last register, so the note
          # still sounding keeps its own pitch and shape until the strike.
          module Strikes
            STRIKING = "rt strikes striking" # 1 while a tick's pass over the effects plays
            BLANK_LINES = "rt strikes blank lines" # Lines from power-on to the last blank's start, 16 bits
            BASE = "rt strikes base" # The line the frame playing starts on, 16 bits
            ACCUM = "rt strikes accum" # The tick playing's place in the frame, in lines over 2^FRACT
            DUE = "rt strikes due" # The line the tick playing's writes are due on, 16 bits
            HEAD = "rt strikes head" # The oldest entry, as its place in the list
            TAIL = "rt strikes tail" # Where the next goes
            LIST = "rt strikes list" # A page of entries: the register, the value, the line it is due on

            ENTRY_BYTES = 4
            LINES_A_FRAME = 154
            BLANK_LINE = 144
            # The timer counts 1024 of the processor's cycles at double speed, and a line is 912 of
            # them: 57 of its counts are 64 lines.
            COUNTS_PER_64_LINES = 57
            TIMER_ON = 0x04 # TAC: running, at the processor's clock over 1024
            # A frame's strikes are timed from this many lines after its blank, some 3.5 milliseconds:
            # the music is played after the blank's copies, and a tick at the frame's start is still to
            # come when it is listed.
            PLAYED_BY = 32
            # ...and a frame whose music is played later than that, a pass of the game having taken
            # longer than a frame, from this many lines after it is played, half a frame: the frames
            # of the next slow pass are then played before the lines the frames before them reach,
            # however much longer that pass takes, and stay a frame apart from them.
            LATE_BY = LINES_A_FRAME / 2

            # A voice's last register, whose top bit starts the note: a write folded into a listed
            # one keeps the listed start.
            STARTS = Console::GBCHardware.then { |h| [h::NR14, h::NR24, h::NR34, h::NR44].map { |r| r & 0xFF } }.freeze

            module_function

            # Reserved in a game whose recording holds the timer: the alarm is the display's line match.
            LINE_ALARM = "rt strikes line alarm"
            # ...and there, above nought while the game's side reads or writes the list (#emit_hold_alarm).
            BUSY = "rt strikes busy"

            # In such a game whose status bar covers the sprites, the line match is shared with the bar's top
            # (#emit_line_match_set): the line each wants it on, plus one, and nought for none.
            STRIKE_AT = "rt strikes strike at"
            BAR_AT = "rt strikes bar at"

            # +bar+ for a game with +line+ whose status bar covers the sprites (Runtime::Picture::BAR_COVERS).
            def reserve(memory, line: false, bar: false)
              [STRIKING, HEAD, TAIL].each { |name| memory.reserve(name, 1) }
              [LINE_ALARM, BUSY].each { |name| memory.reserve(name, 1) } if line
              [STRIKE_AT, BAR_AT].each { |name| memory.reserve(name, 1) } if line && bar
              [BLANK_LINES, BASE, ACCUM, DUE].each { |name| memory.reserve(name, 2) }
              memory.reserve_in_page(LIST, 0x100)
            end

            def any?(memory) = memory.reserved?(LIST)

            # Is the alarm the display's line match (#emit_set_line), the timer being a recording's?
            def line?(memory) = memory.reserved?(LINE_ALARM)

            # Where the line match is shared with the bar, a strike due this many lines or fewer before the
            # bar's line waits for it and is answered after it: the bar's switch must go over at the end of
            # its line, and the interrupt answering a strike just before could still be running then.
            BAR_FIRST_BY = 8

            # Does the line match serve the strikes and a status bar covering the sprites both?
            def bar_shared?(memory) = memory.reserved?(BAR_AT)

            # The interrupt the alarm raises.
            def alarm_interrupt(memory) = line?(memory) ? Console::GBCHardware::INT_STAT : Console::GBCHardware::INT_TIMER

            # The tick's place in its frame is kept in lines over 2^fraction_bits: lines and 256ths
            # where a tick is shorter than 255 lines, whole lines where it is longer (and a frame then
            # holds one tick at most). +step+ is IR::Tunes.effect_clock_step; the answer is
            # [the lines a tick is, in those, the fraction's bits].
            def tick_lines(step)
              exact = Rational(LINES_A_FRAME * IR::Tunes::CLOCK_MODULUS, step)
              exact < 255 ? [(exact * 256).round, 8] : [exact.round, 0]
            end

            def emit(asm, memory, step)
              emit_put(asm, memory)
              emit_listed(asm, memory)
              emit_drop(asm, memory)
              emit_line_now(asm, memory)
              emit_due(asm, memory)
              emit_alarm(asm) unless line?(memory)
              emit_line_match_set(asm, memory) if bar_shared?(memory)
              emit_line_end(asm, memory) if line?(memory)
              emit_frame(asm, memory, step)
              emit_later(asm)
              emit_multiply(asm)
              %w[above below].each do |side|
                asm.label("rt_sfx_#{side}_struck")
                asm.load(:a, 1)
                asm.load([memory[STRIKING]], :a)
                asm.call("rt_sfx_#{side}")
                asm.xor_a(:a)
                asm.load([memory[STRIKING]], :a)
                asm.ret
              end
            end

            # At the blank, inline in the screen's interrupt, first: a frame more of lines.
            def emit_blank(asm, memory)
              at = memory[BLANK_LINES]
              asm.load(:a, [at])
              asm.add_a(LINES_A_FRAME)
              asm.load([at], :a)
              asm.load(:a, [at + 1])
              asm.adc_a(0)
              asm.load([at + 1], :a)
            end

            # rt_sound_put (A = the value, C = the register, as LDH [C] names it): onto the list,
            # during a tick's pass; otherwise into the latest listed write of the register, or the
            # register now. Keeps every register and the flags.
            def emit_put(asm, memory)
              page = memory[LIST] >> 8
              asm.label("rt_sound_put")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              asm.load(:b, :a)
              emit_hold_alarm(asm, memory)
              asm.load(:a, [memory[STRIKING]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sound_put_outside")
              asm.label("rt_sound_put_room")
              asm.load(:a, [memory[TAIL]])
              asm.load(:e, :a)
              asm.add_a(ENTRY_BYTES)
              asm.load(:d, :a)
              asm.load(:a, [memory[HEAD]])
              asm.cp_a(:d)
              asm.jump_relative(:nz, "rt_sound_put_listed")
              asm.call("rt_strikes_flush") # full: everything listed written now
              asm.jump_relative("rt_sound_put_room")
              asm.label("rt_sound_put_listed")
              asm.load(:a, :d)
              asm.load([memory[TAIL]], :a)
              asm.load(:h, page)
              asm.load(:l, :e)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.load(:a, :b)
              asm.load([:hli], :a)
              asm.load(:a, [memory[DUE]])
              asm.load([:hli], :a)
              asm.load(:a, [memory[DUE] + 1])
              asm.load([:hl], :a)
              asm.jump("rt_sound_put_done")

              asm.label("rt_sound_put_outside")
              asm.load(:d, 1) # where the latest of the register is: 1, an odd place, for none
              asm.load(:a, [memory[HEAD]])
              asm.load(:e, :a)
              asm.label("rt_sound_put_look")
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:e)
              asm.jump_relative(:z, "rt_sound_put_looked")
              asm.load(:h, page)
              asm.load(:l, :e)
              asm.load(:a, [:hl])
              asm.cp_a(:c)
              asm.jump_relative(:nz, "rt_sound_put_other")
              asm.load(:d, :e)
              asm.label("rt_sound_put_other")
              asm.load(:a, :e)
              asm.add_a(ENTRY_BYTES)
              asm.load(:e, :a)
              asm.jump_relative("rt_sound_put_look")
              asm.label("rt_sound_put_looked")
              asm.bit(0, :d)
              asm.jump_relative(:nz, "rt_sound_put_now")
              asm.load(:h, page)
              asm.load(:l, :d)
              asm.inc(:l) # the listed value
              STARTS.each do |start|
                asm.load(:a, :c)
                asm.cp_a(start)
                asm.jump_relative(:z, "rt_sound_put_start")
              end
              asm.load(:a, :b)
              asm.load([:hl], :a)
              asm.jump_relative("rt_sound_put_done")
              asm.label("rt_sound_put_start")
              asm.load(:a, [:hl])
              asm.and_a(0x80)
              asm.or_a(:b)
              asm.load([:hl], :a)
              asm.jump_relative("rt_sound_put_done")
              asm.label("rt_sound_put_now")
              asm.load(:a, :b)
              asm.load_high([:c], :a)
              asm.label("rt_sound_put_done")
              emit_let_alarm(asm, memory)
              %i[hl de bc af].each { |pair| asm.pop(pair) }
              asm.ret
            end

            # rt_sound_listed (C = a register, as LDH [C] names it): A = the value the latest listed write of
            # it holds, or the register's own where none is listed. For a register several voices share, the
            # speakers' switches (NR51): a write that changes one voice's switches starts from what the
            # others' will be once the list is struck, so folded into a listed write (rt_sound_put) it keeps
            # theirs. Keeps every other register.
            def emit_listed(asm, memory)
              page = memory[LIST] >> 8
              asm.label("rt_sound_listed")
              %i[bc de hl].each { |pair| asm.push(pair) }
              emit_hold_alarm(asm, memory)
              asm.load_high(:a, [:c])
              asm.load(:d, :a) # the register now
              asm.load(:h, page)
              asm.load(:a, [memory[HEAD]])
              asm.load(:l, :a)
              asm.label("rt_sound_listed_look")
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:l)
              asm.jump_relative(:z, "rt_sound_listed_looked")
              asm.load(:a, [:hl])
              asm.cp_a(:c)
              asm.jump_relative(:nz, "rt_sound_listed_other")
              asm.inc(:l)
              asm.load(:a, [:hl])
              asm.load(:d, :a)
              asm.dec(:l)
              asm.label("rt_sound_listed_other")
              asm.load(:a, :l)
              asm.add_a(ENTRY_BYTES)
              asm.load(:l, :a)
              asm.jump_relative("rt_sound_listed_look")
              asm.label("rt_sound_listed_looked")
              emit_let_alarm(asm, memory)
              asm.load(:a, :d)
              %i[hl de bc].each { |pair| asm.pop(pair) }
              asm.ret
            end

            # What a dropped entry names: FF27, where the sound chip has no register and a write does
            # nothing (Pan Docs, "Audio Registers"), so striking it writes nothing.
            DROPPED = 0x27

            # rt_strikes_drop (C = a register, as LDH [C] names it), for the game's own sound, written now:
            # every listed write of the register dropped, so the strike does not overtake the game's sound
            # (IR::Tunes, "The game's own sound against a listed strike"). For the speakers' switches
            # (NR51), which every voice shares, rt_strikes_speakers_set instead. Keeps every register.
            #
            # rt_strikes_speakers_set (A = switches): the switches set in every listed write of NR51, for
            # the game's own sound, which plays its voice from both speakers. Keeps every register.
            def emit_drop(asm, memory)
              page = memory[LIST] >> 8
              asm.label("rt_strikes_drop")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              asm.load(:d, 0) # dropping
              asm.jump_relative("rt_strikes_drop_body")
              asm.label("rt_strikes_speakers_set")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              asm.load(:e, :a)
              asm.load(:c, Console::GBCHardware::NR51 & 0xFF)
              asm.load(:d, 1) # setting switches
              asm.label("rt_strikes_drop_body")
              emit_hold_alarm(asm, memory)
              asm.load(:h, page)
              asm.load(:a, [memory[HEAD]])
              asm.load(:l, :a)
              asm.label("rt_strikes_drop_look")
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:l)
              asm.jump_relative(:z, "rt_strikes_drop_looked")
              asm.load(:a, [:hl])
              asm.cp_a(:c)
              asm.jump_relative(:nz, "rt_strikes_drop_other")
              asm.bit(0, :d)
              asm.jump_relative(:nz, "rt_strikes_drop_switches")
              asm.load(:a, DROPPED)
              asm.load([:hl], :a)
              asm.jump_relative("rt_strikes_drop_other")
              asm.label("rt_strikes_drop_switches")
              asm.inc(:l)
              asm.load(:a, [:hl])
              asm.or_a(:e)
              asm.load([:hl], :a)
              asm.dec(:l)
              asm.label("rt_strikes_drop_other")
              asm.load(:a, :l)
              asm.add_a(ENTRY_BYTES)
              asm.load(:l, :a)
              asm.jump_relative("rt_strikes_drop_look")
              asm.label("rt_strikes_drop_looked")
              emit_let_alarm(asm, memory)
              %i[hl de bc af].each { |pair| asm.pop(pair) }
              asm.ret
            end

            # The timer's interrupt held off while the list is read or written, whether or not the
            # interrupts are on: IE without the timer, IE as it was kept on the stack. The music is
            # played with only the timer's interrupt let in (Runtime::Frame), so a strike due as it
            # plays is struck then, and never in the middle of the list being changed. Uses A.
            #
            # Where the alarm is the line match (#line?), the display's interrupt is a bent screen's too, and
            # held off it would leave rows unbent while the music plays. So it is not held off: the list is
            # marked BUSY instead, a count that holds nested holds, and the interrupt and the blank's
            # interrupt leave the strikes for a line later while it is (#emit_strikes_unless_busy).
            def emit_hold_alarm(asm, memory)
              h = Console::GBCHardware
              if line?(memory)
                asm.load(:a, [memory[BUSY]])
                asm.inc(:a)
                asm.load([memory[BUSY]], :a)
                asm.push(:af)
                return
              end
              asm.load_high(:a, h::IE)
              asm.push(:af)
              asm.and_a(~alarm_interrupt(memory) & 0xFF)
              asm.load_high(h::IE, :a)
            end

            # ...and let in again as it was. Uses A and the flags.
            def emit_let_alarm(asm, memory)
              asm.pop(:af)
              if line?(memory)
                asm.load(:a, [memory[BUSY]])
                asm.dec(:a)
                asm.load([memory[BUSY]], :a)
                return
              end
              asm.load_high(Console::GBCHardware::IE, :a)
            end

            # In the display's interrupt or the blank's, where the alarm is the line match: to +busy+ while
            # the list is BUSY, LYC set for the line after this one, so the strikes are tried again then.
            # Uses A.
            def emit_strikes_unless_busy(asm, memory, busy)
              asm.load(:a, [memory[BUSY]])
              asm.and_a(:a)
              asm.jump_relative(:z, "#{busy}_free")
              emit_line_after_this(asm)
              asm.jump(busy)
              asm.label("#{busy}_free")
            end

            # LYC the line after the one the display is on, inline, or the first line drawn from the blank on:
            # a bent screen reads the coincidence flag as each line drawn ends, and no line in the blank does.
            # Uses A.
            def emit_line_after_this(asm)
              h = Console::GBCHardware
              label = "rt_line_after_#{asm.here}"
              asm.load_high(:a, h::LY)
              asm.inc(:a)
              asm.cp_a(BLANK_LINE)
              asm.jump_relative(:c, label)
              asm.xor_a(:a)
              asm.label(label)
              asm.load_high(h::LYC, :a)
            end

            # rt_line_now: HL = the line the display is on, counted from power-on. A blank whose
            # interrupt has yet to come has moved BLANK_LINES on by nothing, so it counts a frame more.
            # Keeps BC and DE.
            def emit_line_now(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_line_now")
              asm.load_high(:a, h::LY)
              asm.sub_a(BLANK_LINE)
              asm.jump_relative(:nc, "rt_line_now_blank")
              asm.add_a(LINES_A_FRAME)
              asm.label("rt_line_now_blank")
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.load_high(:a, h::IF)
              asm.and_a(h::INT_VBLANK)
              asm.jump_relative(:z, "rt_line_now_known")
              asm.load(:a, :l)
              asm.add_a(LINES_A_FRAME)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.label("rt_line_now_known")
              asm.load(:a, [memory[BLANK_LINES]])
              asm.add_a(:l)
              asm.load(:l, :a)
              asm.load(:a, [memory[BLANK_LINES] + 1])
              asm.adc_a(:h)
              asm.load(:h, :a)
              asm.ret
            end

            # rt_strikes_due: every entry whose line has come written, oldest first, and the timer
            # set going for the next, or stopped. rt_strikes_flush: every entry written, whatever its
            # line. Both keep every register and the flags.
            def emit_due(asm, memory)
              h = Console::GBCHardware
              page = memory[LIST] >> 8
              asm.label("rt_strikes_flush")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              asm.load(:a, 1)
              asm.jump_relative("rt_strikes_body")
              asm.label("rt_strikes_due")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              asm.xor_a(:a)
              asm.label("rt_strikes_body")
              asm.load(:b, :a)
              emit_hold_alarm(asm, memory)
              asm.load(:a, :b)
              asm.push(:af) # whether every entry is written: kept at the top of the stack
              asm.label("rt_strikes_next")
              asm.load(:a, [memory[HEAD]])
              asm.load(:c, :a)
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:c)
              asm.jump(:z, "rt_strikes_empty")
              asm.load(:b, page) # BC = the entry
              asm.pop(:af)
              asm.push(:af)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_strikes_write")
              asm.call("rt_line_now")
              asm.inc(:c)
              asm.inc(:c)
              asm.load(:a, [:bc])
              asm.sub_a(:l)
              asm.load(:e, :a)
              asm.inc(:c)
              asm.load(:a, [:bc])
              asm.sbc_a(:h)
              asm.load(:d, :a) # DE = its line less the line now
              asm.dec(:c)
              asm.dec(:c)
              asm.dec(:c)
              asm.bit(7, :d)
              asm.jump_relative(:nz, "rt_strikes_write")
              asm.or_a(:e)
              asm.jump_relative(:z, "rt_strikes_write")
              line?(memory) ? emit_set_line(asm, memory) : emit_set_timer(asm)
              asm.jump_relative("rt_strikes_out")

              asm.label("rt_strikes_write")
              asm.load(:a, :c)
              asm.add_a(ENTRY_BYTES)
              asm.load([memory[HEAD]], :a)
              asm.load(:a, [:bc]) # the register
              asm.inc(:c)
              asm.load(:e, :a)
              asm.load(:a, [:bc]) # the value
              asm.load(:c, :e)
              asm.load_high([:c], :a)
              asm.jump("rt_strikes_next")

              asm.label("rt_strikes_empty")
              if bar_shared?(memory)
                asm.xor_a(:a)
                asm.load([memory[STRIKE_AT]], :a)
                asm.call("rt_line_match_set")
              elsif line?(memory)
                asm.load_high(:a, h::STAT)
                asm.and_a(~Picture::STAT_LINE_MATCH & 0xFF)
                asm.load_high(h::STAT, :a)
              else
                asm.xor_a(:a)
                asm.load_high(h::TAC, :a)
              end
              asm.label("rt_strikes_out")
              asm.pop(:af)
              emit_let_alarm(asm, memory)
              %i[hl de bc af].each { |pair| asm.pop(pair) }
              asm.ret
            end

            # The timer set going to run out DE lines from now (1 or more): its counts DE × 57 ÷ 64,
            # rounded up, and as many as it holds where that is more.
            def emit_set_timer(asm)
              h = Console::GBCHardware
              asm.load(:a, :d)
              asm.cp_a(2)
              asm.load(:a, 255)
              asm.jump_relative(:nc, "rt_strikes_counts")
              asm.load(:h, :d)
              asm.load(:l, :e)
              3.times { asm.add_hl(:hl) } # DE × 8
              asm.load(:a, :l)
              asm.sub_a(:e)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.sbc_a(:d)
              asm.load(:h, :a) # × 7
              3.times { asm.add_hl(:hl) } # × 56
              asm.add_hl(:de) # × 57
              asm.load(:de, 63)
              asm.add_hl(:de)
              6.times do
                asm.srl(:h)
                asm.rr(:l)
              end
              asm.load(:a, :h)
              asm.and_a(:a)
              asm.load(:a, :l)
              asm.jump_relative(:z, "rt_strikes_counts")
              asm.load(:a, 255)
              asm.label("rt_strikes_counts")
              asm.cpl
              asm.inc(:a) # 256 less the counts
              asm.load(:b, :a)
              asm.xor_a(:a)
              asm.load_high(h::TAC, :a)
              asm.load(:a, :b)
              asm.load_high(h::TIMA, :a)
              asm.load_high(h::TMA, :a)
              asm.load(:a, TIMER_ON)
              asm.load_high(h::TAC, :a)
            end

            # The display's line match set for DE lines from now (1 or more), in a game whose recording
            # holds the timer: LYC the line the display will be on then, or the line before this one,
            # a frame on, where that is further. The display raises its interrupt as it starts that
            # line (Pan Docs, "LCD Status Registers"), and the line interrupt answers it with
            # rt_strikes_due (Runtime::Picture, rt_hblank_interrupt); written as the display is on that
            # line already, it raises it at once. Where a status bar shares the line match, the line is
            # kept in STRIKE_AT and rt_line_match_set sets it.
            def emit_set_line(asm, memory)
              h = Console::GBCHardware
              asm.load(:a, :d)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_strikes_line_far")
              asm.load(:a, :e)
              asm.cp_a(LINES_A_FRAME)
              asm.jump_relative(:c, "rt_strikes_line_near")
              asm.label("rt_strikes_line_far")
              asm.load(:e, LINES_A_FRAME - 1)
              asm.label("rt_strikes_line_near")
              asm.load_high(:a, h::LY)
              asm.add_a(:e)
              asm.cp_a(LINES_A_FRAME)
              asm.jump_relative(:c, "rt_strikes_line_set")
              asm.sub_a(LINES_A_FRAME)
              asm.label("rt_strikes_line_set")
              if bar_shared?(memory)
                asm.inc(:a)
                asm.load([memory[STRIKE_AT]], :a)
                asm.call("rt_line_match_set")
                return
              end
              asm.load_high(h::LYC, :a)
              emit_line_match_on(asm, "rt_strikes_line")
            end

            # rt_strikes_line_end: rt_strikes_due as the display's interrupt answers it at a line's end on a
            # screen with bent rows (Runtime::Picture#emit_line_match), where it must be over soon after the
            # next line starts, before that line's own end: the first entry due written, and LYC set for the
            # next, the next line where there are more, and nothing more. A tick's few writes go out a line
            # apart, some 0.1 milliseconds. The display's interrupt is the alarm and is being answered, and a write to the
            # list from the game's side holds it off, so nothing else reads the list meanwhile; the line match
            # is left off, as a bent screen reads the coincidence flag. Keeps every register.
            def emit_line_end(asm, memory)
              h = Console::GBCHardware
              page = memory[LIST] >> 8
              asm.label("rt_strikes_line_end")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              emit_strikes_unless_busy(asm, memory, "rt_strikes_line_end_out")
              asm.call("rt_line_now")
              asm.load(:b, page)
              asm.label("rt_strikes_line_end_next")
              asm.load(:a, [memory[HEAD]])
              asm.load(:c, :a)
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:c)
              asm.jump_relative(:z, "rt_strikes_line_end_out")
              asm.inc(:c)
              asm.inc(:c)
              asm.load(:a, [:bc])
              asm.sub_a(:l)
              asm.load(:e, :a)
              asm.inc(:c)
              asm.load(:a, [:bc])
              asm.sbc_a(:h)
              asm.load(:d, :a) # DE = its line less the line now
              asm.dec(:c)
              asm.dec(:c)
              asm.dec(:c)
              asm.bit(7, :d)
              asm.jump_relative(:nz, "rt_strikes_line_end_write")
              asm.or_a(:e)
              asm.jump_relative(:z, "rt_strikes_line_end_write")
              asm.load(:a, :d)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_strikes_line_end_far")
              asm.load(:a, :e)
              asm.cp_a(LINES_A_FRAME)
              asm.jump_relative(:c, "rt_strikes_line_end_near")
              asm.label("rt_strikes_line_end_far")
              asm.load(:e, LINES_A_FRAME - 1)
              asm.label("rt_strikes_line_end_near")
              asm.load_high(:a, h::LY)
              asm.add_a(:e)
              asm.cp_a(LINES_A_FRAME)
              asm.jump_relative(:c, "rt_strikes_line_end_set")
              asm.sub_a(LINES_A_FRAME)
              asm.label("rt_strikes_line_end_set")
              asm.load_high(h::LYC, :a)
              asm.jump_relative("rt_strikes_line_end_out")
              asm.label("rt_strikes_line_end_write")
              asm.load(:a, :c)
              asm.add_a(ENTRY_BYTES)
              asm.load([memory[HEAD]], :a)
              asm.load(:a, [:bc]) # the register
              asm.inc(:c)
              asm.load(:e, :a)
              asm.load(:a, [:bc]) # the value
              asm.load(:c, :e)
              asm.load_high([:c], :a)
              # One a line: the rest at the next line's end, LYC that line, so this one is over in time.
              asm.load(:a, [memory[HEAD]])
              asm.load(:c, :a)
              asm.load(:a, [memory[TAIL]])
              asm.cp_a(:c)
              asm.jump_relative(:z, "rt_strikes_line_end_out")
              asm.load(:e, 1)
              asm.jump_relative("rt_strikes_line_end_near")
              asm.label("rt_strikes_line_end_out")
              %i[hl de bc af].each { |pair| asm.pop(pair) }
              asm.ret
            end

            # STAT's line match switched on, inline, unless the display's interrupt comes at every line's end
            # for a bent screen: then that interrupt reads the coincidence flag instead, after the next row's
            # bend (Runtime::Picture#emit_line_match_or_line_end), since a line match raised as a line starts
            # would be answered with the bend for the line after it. +name+ makes the label. Uses A.
            def emit_line_match_on(asm, name)
              h = Console::GBCHardware
              asm.load_high(:a, h::STAT)
              asm.bit(3, :a) # Picture::STAT_HBLANK
              asm.jump_relative(:nz, "#{name}_at_line_ends")
              asm.or_a(Picture::STAT_LINE_MATCH)
              asm.load_high(h::STAT, :a)
              asm.label("#{name}_at_line_ends")
            end

            # rt_line_match_set, where the strikes and a status bar covering the sprites share the line
            # match: LYC set to whichever of STRIKE_AT and BAR_AT comes first from the line the display is
            # on, counting on round the frame (the bar first where the strike is BAR_FIRST_BY lines or fewer
            # before it), and the line match switched on; or off for neither. The bar
            # wants the line before its top on the frame being drawn (Runtime::Picture#emit_bar_covers) and
            # the strikes their entry's, which can be on the frame after. Keeps BC, DE and HL.
            def emit_line_match_set(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_line_match_set")
              asm.push(:bc)
              asm.load_high(:a, h::LY)
              asm.load(:c, :a)
              asm.load(:a, [memory[BAR_AT]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_line_match_strike")
              asm.dec(:a)
              emit_lines_on(asm)
              asm.load(:b, :a) # how far on the bar's line is
              asm.load(:a, [memory[STRIKE_AT]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_line_match_bar")
              asm.dec(:a)
              emit_lines_on(asm)
              asm.add_a(BAR_FIRST_BY)
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_line_match_strike")
              asm.label("rt_line_match_bar")
              asm.load(:a, [memory[BAR_AT]])
              asm.jump_relative("rt_line_match_on")
              asm.label("rt_line_match_strike")
              asm.load(:a, [memory[STRIKE_AT]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_line_match_off")
              asm.label("rt_line_match_on")
              asm.dec(:a)
              asm.load_high(h::LYC, :a)
              emit_line_match_on(asm, "rt_line_match")
              asm.pop(:bc)
              asm.ret
              asm.label("rt_line_match_off")
              asm.load_high(:a, h::STAT)
              asm.and_a(~Picture::STAT_LINE_MATCH & 0xFF)
              asm.load_high(h::STAT, :a)
              asm.pop(:bc)
              asm.ret
            end

            # A = how many lines on from line C the line in A is, round the frame, inline. Uses the flags.
            def emit_lines_on(asm)
              label = "rt_lines_on_#{asm.here}"
              asm.sub_a(:c)
              asm.jump_relative(:nc, label)
              asm.add_a(LINES_A_FRAME)
              asm.label(label)
            end

            # rt_strikes_alarm: the timer's interrupt. It is stopped, and rt_strikes_due writes what
            # has come and sets it again.
            def emit_alarm(asm)
              asm.label("rt_strikes_alarm")
              asm.push(:af)
              asm.xor_a(:a)
              asm.load_high(Console::GBCHardware::TAC, :a)
              asm.pop(:af)
              asm.call("rt_strikes_due")
              asm.reti
            end

            # rt_strikes_frame (+clock+'s count, before it moves on): BASE, the frame's first line; and
            # the first tick's line, as the count's 65536ths still to go to it (its complement) times
            # a tick's lines. rt_strikes_next_tick: the next tick's, a tick's lines on. Both set DUE.
            # rt_strikes_frame_start: DUE the frame's start, for a pass that starts the effects asked for
            # (Music#emit_starting_side), or rt_strikes_start_interrupt: DUE the first interrupt's line, where
            # the effects' tempo is counted on a driver's own; rt_strikes_this_tick: DUE the tick playing's line again.
            def emit_frame(asm, memory, step)
              clock = memory[Music::EFFECT_CLOCK]
              lines, fraction_bits = tick_lines(step)
              base = memory[BASE]
              accum = memory[ACCUM]
              asm.label("rt_strikes_frame")
              asm.load(:a, [base])
              asm.add_a(LINES_A_FRAME)
              asm.load(:l, :a)
              asm.load(:a, [base + 1])
              asm.adc_a(0)
              asm.load(:h, :a) # HL = a frame after the frame before
              asm.load(:a, [memory[BLANK_LINES]])
              asm.add_a(PLAYED_BY)
              asm.load(:e, :a)
              asm.load(:a, [memory[BLANK_LINES] + 1])
              asm.adc_a(0)
              asm.load(:d, :a)
              asm.call("rt_strikes_later") # ...or PLAYED_BY after the last blank
              asm.push(:hl)
              asm.call("rt_line_now")
              asm.pop(:de)
              asm.load(:a, :l)
              asm.sub_a(:e)
              asm.load(:a, :h)
              asm.sbc_a(:d)
              asm.bit(7, :a)
              asm.jump_relative(:z, "rt_strikes_frame_late")
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.jump_relative("rt_strikes_frame_after")
              asm.label("rt_strikes_frame_late") # ...or LATE_BY after now, if the music is played later still
              asm.load(:de, LATE_BY)
              asm.add_hl(:de)
              asm.label("rt_strikes_frame_after")
              asm.load(:a, :l)
              asm.load([base], :a)
              asm.load(:a, :h)
              asm.load([base + 1], :a)
              asm.load(:a, [clock])
              asm.cpl
              asm.load(:c, :a)
              asm.load(:a, [clock + 1])
              asm.cpl
              asm.load(:b, :a)
              asm.load(:de, lines)
              asm.call("rt_strikes_multiply")
              asm.jump_relative("rt_strikes_tick_at")

              asm.label("rt_strikes_frame_start")
              asm.load(:a, [base])
              asm.load([memory[DUE]], :a)
              asm.load(:a, [base + 1])
              asm.load([memory[DUE] + 1], :a)
              asm.ret

              if memory.reserved?(Music::START_PLACE) # the first interrupt's place (Music#emit_find_first_tick)
                asm.label("rt_strikes_start_interrupt")
                asm.load(:a, [memory[Music::START_PLACE]])
                asm.load(:l, :a)
                asm.load(:a, [memory[Music::START_PLACE] + 1])
                asm.load(:h, :a)
                asm.jump_relative("rt_strikes_due_at")
              end

              asm.label("rt_strikes_this_tick")
              asm.load(:a, [accum])
              asm.load(:l, :a)
              asm.load(:a, [accum + 1])
              asm.load(:h, :a)
              asm.jump_relative("rt_strikes_tick_at")

              asm.label("rt_strikes_next_tick")
              asm.load(:a, [accum])
              asm.add_a(lines & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, [accum + 1])
              asm.adc_a(lines >> 8)
              asm.load(:h, :a)
              asm.label("rt_strikes_tick_at")
              asm.load(:a, :l)
              asm.load([accum], :a)
              asm.load(:a, :h)
              asm.load([accum + 1], :a)
              asm.label("rt_strikes_due_at")
              if fraction_bits == 8
                asm.load(:l, :h)
                asm.load(:h, 0)
              end
              asm.load(:a, [base])
              asm.add_a(:l)
              asm.load([memory[DUE]], :a)
              asm.load(:a, [base + 1])
              asm.adc_a(:h)
              asm.load([memory[DUE] + 1], :a)
              asm.ret
            end

            # rt_strikes_later: HL = the later of the lines in HL and DE. Uses A.
            def emit_later(asm)
              asm.label("rt_strikes_later")
              asm.load(:a, :e)
              asm.sub_a(:l)
              asm.load(:a, :d)
              asm.sbc_a(:h)
              asm.bit(7, :a)
              asm.ret(:nz) # DE comes before HL: the distance between them is below nought
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.ret
            end

            # rt_strikes_multiply: HL = the top half of DE × BC, and BC its bottom half. Uses A.
            def emit_multiply(asm)
              asm.label("rt_strikes_multiply")
              asm.load(:hl, 0)
              asm.load(:a, 16)
              asm.label("rt_strikes_multiply_bit")
              asm.push(:af)
              asm.bit(0, :c)
              asm.jump_relative(:nz, "rt_strikes_multiply_add")
              asm.and_a(:a) # carry clear
              asm.jump_relative("rt_strikes_multiply_shift")
              asm.label("rt_strikes_multiply_add")
              asm.add_hl(:de)
              asm.label("rt_strikes_multiply_shift")
              asm.rr(:h)
              asm.rr(:l)
              asm.rr(:b)
              asm.rr(:c)
              asm.pop(:af)
              asm.dec(:a)
              asm.jump_relative(:nz, "rt_strikes_multiply_bit")
              asm.ret
            end
          end
        end
      end
    end
  end
end
